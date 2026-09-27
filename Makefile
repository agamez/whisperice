# =============================================================================
# wspr-icebreaker Makefile  (Phase 1 -- iCEBreaker infrastructure + VHDL-93)
# =============================================================================
#
# Reproducible build flow for the iCEBreaker (Lattice iCE40UP5K, package SG48):
#
#     make          synthesize (Yosys) -> place & route (nextpnr-ice40)
#                   -> bitstream (icepack), plus a timing report (icetime)
#     make sim      GHDL --std=93 analyze/elaborate/run the Phase 1 testbench
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
TB_TOP   := sim/tb_top.vhd

BUILD    := build
WORK     := $(BUILD)/ghdl

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

# `make` with no target builds the bitstream (orchestrator plan section 30-A).
.DEFAULT_GOAL := all

.PHONY: help all build sim prog clean

# -----------------------------------------------------------------------------
help:
	@echo "wspr-icebreaker -- Phase 1 (iCEBreaker infrastructure + VHDL-93)"
	@echo ""
	@echo "  make build   synthesize + place&route + bitstream  ->  $(BIN)"
	@echo "  make sim     GHDL --std=93 analyze/elaborate/run   $(TB_TOP)"
	@echo "  make prog    program the board with iceprog (board must be attached)"
	@echo "  make clean   remove $(BUILD)/"
	@echo "  make help    this message"
	@echo ""
	@echo "Target device : iCE40UP5K / SG48 (iCEBreaker), nextpnr --freq 12"
	@echo "Toolchain     : $(OSS_CAD_SUITE)"

# -----------------------------------------------------------------------------
all: build

build: $(BIN)

# --- Yosys: VHDL-93 elaboration + iCE40 synthesis ---------------------------
$(JSON): $(SRC_TOP)
	@mkdir -p $(BUILD)
	@echo "=== toolchain ==="
	@$(YOSYS) -V
	@$(NEXTPNR) --version
	@$(GHDL) --version | head -1
	@echo "=== yosys: synthesize $(TOP) (ghdl --std=93) ==="
	$(YOSYS) -m ghdl -p "ghdl --std=93 $(SRC_TOP) -e $(TOP); synth_ice40 -top $(TOP) -json $@"

# --- nextpnr-ice40: place & route -------------------------------------------
$(ASC): $(JSON) $(PCF)
	@echo "=== nextpnr: place & route (up5k / sg48) ==="
	$(NEXTPNR) --up5k --package sg48 --pcf $(PCF) --json $< --asc $@ --freq 12

# --- icepack: bitstream, then icetime static timing -------------------------
$(BIN): $(ASC) $(PCF)
	@echo "=== icepack: bitstream ==="
	$(ICEPACK) $< $@
	@echo "=== icetime: static timing analysis ($(ASC)) ==="
	$(ICETIME) -d up5k $<

# --- Simulation: GHDL, always --std=93 --------------------------------------
# `-o $(BUILD)/tb_top` keeps the elaborated executable (and its e~*.o object)
# under build/, so the repo tree stays clean.
sim: $(SRC_TOP) $(TB_TOP)
	@mkdir -p $(WORK)
	@echo "=== toolchain ==="
	@$(GHDL) --version | head -1
	@echo "=== ghdl --std=93: analyze / elaborate / run tb_top ==="
	$(GHDL) -a --std=93 --workdir=$(WORK) $(SRC_TOP)
	$(GHDL) -a --std=93 --workdir=$(WORK) $(TB_TOP)
	$(GHDL) -e --std=93 --workdir=$(WORK) -o $(BUILD)/tb_top tb_top
	$(BUILD)/tb_top --assert-level=error

# --- Programming (requires an attached iCEBreaker) ---------------------------
prog: $(BIN)
	@echo "=== iceprog: programming $(BIN) ==="
	@echo "NOTE: this needs the iCEBreaker attached (lsusb | grep 0403:6010)"
	iceprog $(BIN)

# --- Housekeeping ------------------------------------------------------------
clean:
	rm -rf $(BUILD)
	@echo "cleaned $(BUILD)/"
