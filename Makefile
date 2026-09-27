# =============================================================================
# wspr-icebreaker Makefile  (iCEBreaker infrastructure + VHDL-93)
# =============================================================================
#
# Reproducible build flow for the iCEBreaker (Lattice iCE40UP5K, package SG48):
#
#     make          synthesize (Yosys) -> place & route (nextpnr-ice40)
#                   -> bitstream (icepack), plus a timing report (icetime)
#     make sim      GHDL --std=93 analyze/elaborate/run the full testbench suite
#     make prog     program the attached iCEBreaker (iceprog)
#     make clean    remove everything under build/
#     make help     short usage summary
#
# Hard rules honoured here:
#   * all HDL is VHDL-93; every ghdl invocation passes --std=93 explicitly
#     (AGENTS.md section 2.1).
#   * build artifacts live only under build/, keeping the repo tree clean.
#   * pins come only from constraints/icebreaker.pcf (spec section 11).
#
# Toolchain: oss-cad-suite (yosys 0.69+, nextpnr-ice40, icepack, icetime, ghdl).
# =============================================================================

SHELL := /bin/bash

# --- Project layout ----------------------------------------------------------
TOP      := top
PCF      := constraints/icebreaker.pcf
SRC_TOP  := src/top.vhd

BUILD     := build
SIM_BUILD := $(BUILD)/sim

JSON     := $(BUILD)/$(TOP).json
ASC      := $(BUILD)/$(TOP).asc
BIN      := $(BUILD)/$(TOP).bin

# --- Toolchain ---------------------------------------------------------------
# oss-cad-suite ships yosys / nextpnr-ice40 / icepack / icetime / ghdl.
# Prepend its bin/ so the tools resolve even from a non-login shell (the suite's
# environment script is normally sourced by login shells only).
OSS_CAD_SUITE ?= /opt/oss-cad-suite
export PATH := $(OSS_CAD_SUITE)/bin:$(PATH)

YOSYS   := yosys
NEXTPNR := nextpnr-ice40
ICEPACK := icepack
ICETIME := icetime
GHDL    := ghdl

# Defensive bootstrap: if yosys still cannot be resolved from the exported PATH
# (e.g. a minimal shell), source the oss-cad-suite environment in the recipe.
OSS_ENV = if ! command -v yosys >/dev/null 2>&1; then echo "note: sourcing $(OSS_CAD_SUITE)/environment"; . $(OSS_CAD_SUITE)/environment; fi;

# -----------------------------------------------------------------------------
# RTL_SIM_DEPS -- all synthesizable RTL, in dependency (analysis) order.
#
# GHDL requires every entity to be analyzed before the entity that instantiates
# it.  The only cross-entity dependency in this set is
#     wspr_symbols  instantiates  wspr_sync   (src/wspr/wspr_symbols.vhd:39)
# so wspr_sync is listed first.  Every other file in the set is a leaf (it
# contains library/use clauses only, no `entity work.*` instantiation), hence
# the remaining ordering is by subsystem: GPS -> timing -> NCO -> WSPR codec.
# -----------------------------------------------------------------------------
RTL_SIM_DEPS := \
	src/gps/gps_uart.vhd \
	src/gps/gps_parser.vhd \
	src/gps/gps_time.vhd \
	src/gps/pps_measure.vhd \
	src/timing/clock_calibration.vhd \
	src/timing/wspr_scheduler.vhd \
	src/nco/nco.vhd \
	src/wspr/wspr_message.vhd \
	src/wspr/wspr_fec.vhd \
	src/wspr/wspr_interleave.vhd \
	src/wspr/wspr_sync.vhd \
	src/wspr/wspr_symbols.vhd \
	src/wspr/wspr_modulator.vhd

# Testbench suite.  tb_wspr_top is guarded by a file-existence check in the
# `sim` recipe because it is authored separately and may not exist yet.
SIM_TBS := \
	tb_wspr_top \
	tb_gps_uart \
	tb_gps_parser \
	tb_gps_time \
	tb_pps_measure \
	tb_clock_calibration \
	tb_nco \
	tb_wspr_message \
	tb_wspr_fec \
	tb_wspr_interleave \
	tb_wspr_symbols \
	tb_wspr_modulator

# `make` with no target builds the bitstream (orchestrator plan section 30-A).
.DEFAULT_GOAL := all

.PHONY: help all build sim prog clean

# -----------------------------------------------------------------------------
help:
	@echo "wspr-icebreaker -- iCEBreaker infrastructure + VHDL-93"
	@echo ""
	@echo "  make build   synthesize + place&route + bitstream  ->  $(BIN)"
	@echo "  make sim     GHDL --std=93 analyze/elaborate/run the testbench suite"
	@echo "  make prog    program the board with iceprog (board must be attached)"
	@echo "  make clean   remove $(BUILD)/"
	@echo "  make help    this message"
	@echo ""
	@echo "Testbenches run by 'make sim' (each in $(SIM_BUILD)/<tb>):"
	@for tb in $(SIM_TBS); do echo "    $$tb"; done
	@echo ""
	@echo "Target device : iCE40UP5K / SG48 (iCEBreaker), nextpnr --freq 12"
	@echo "Toolchain     : $(OSS_CAD_SUITE)"

# -----------------------------------------------------------------------------
all: build

# --- Build: Yosys -> nextpnr -> icepack -> icetime --------------------------
# The full RTL set is analyzed before src/top.vhd so that the top-level entity
# (which instantiates the blocks) resolves.  `$(OSS_ENV)` is a no-op when the
# exported PATH already finds yosys.
build:
	@mkdir -p $(BUILD)
	@$(OSS_ENV) \
	echo "=== toolchain ===" \
	&& $(YOSYS) -V \
	&& $(NEXTPNR) --version \
	&& $(GHDL) --version | head -1 \
	&& echo "=== yosys: synthesize $(TOP) (ghdl --std=93, full RTL) ===" \
	&& $(YOSYS) -m ghdl -p "ghdl --std=93 $(RTL_SIM_DEPS) $(SRC_TOP) -e $(TOP); synth_ice40 -top $(TOP) -json $(JSON)" \
	&& echo "=== nextpnr: place & route (up5k / sg48) ===" \
	&& $(NEXTPNR) --up5k --package sg48 --pcf $(PCF) --json $(JSON) --asc $(ASC) --freq 12 \
	&& echo "=== icepack: bitstream ===" \
	&& $(ICEPACK) $(ASC) $(BIN) \
	&& echo "=== icetime: static timing analysis ($(ASC)) ===" \
	&& $(ICETIME) -d up5k $(ASC)

# --- Simulation: GHDL, always --std=93 --------------------------------------
# Each testbench gets its own fresh workdir under $(SIM_BUILD)/<tb> so that
# stale library entries can never leak between runs.  The elaborated executable
# is written under build/ (never the repo root).  Analysis covers all RTL for
# every TB (correctness over minimalism); for tb_wspr_top the top-level source
# is added as well.  Execution stops on the first failure.
sim:
	@mkdir -p $(SIM_BUILD)
	@$(OSS_ENV) \
	for tb in $(SIM_TBS); do \
		dir=$(SIM_BUILD)/$$tb; \
		if [ ! -s sim/$$tb.vhd ]; then \
			echo "SKIP $$tb (sim/$$tb.vhd missing or empty yet)"; \
			continue; \
		fi; \
		rm -rf $$dir; \
		mkdir -p $$dir; \
		srcs="$(RTL_SIM_DEPS)"; \
		case $$tb in tb_wspr_top) srcs="$(RTL_SIM_DEPS) $(SRC_TOP)";; esac; \
		if $(GHDL) -a --std=93 --workdir=$$dir $$srcs sim/$$tb.vhd >$$dir/analyze.log 2>&1 \
		   && $(GHDL) -e --std=93 --workdir=$$dir -o $$dir/$$tb $$tb >$$dir/elaborate.log 2>&1 \
		   && $$dir/$$tb --assert-level=error >$$dir/run.log 2>&1; then \
			echo "PASS $$tb"; \
		else \
			echo "FAIL $$tb"; \
			echo "--- analyze.log ---"; tail -n 20 $$dir/analyze.log 2>/dev/null; \
			echo "--- elaborate.log ---"; tail -n 20 $$dir/elaborate.log 2>/dev/null; \
			echo "--- run.log ---"; tail -n 40 $$dir/run.log 2>/dev/null; \
			exit 1; \
		fi; \
	done; \
	echo "=== all available testbenches passed ==="

# --- Programming (requires an attached iCEBreaker) ---------------------------
prog: build
	@echo "=== iceprog: programming $(BIN) ==="
	@echo "NOTE: this needs the iCEBreaker attached (lsusb | grep 0403:6010)"
	iceprog $(BIN)

# --- Housekeeping ------------------------------------------------------------
clean:
	rm -rf $(BUILD)
	@echo "cleaned $(BUILD)/"
