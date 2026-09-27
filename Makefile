# wspr-icebreaker Makefile — STUB
#
# This file is a placeholder created by the Setup Agent (environment scaffolding only).
# The real build flow (yosys -> nextpnr-ice40 -> icepack, GHDL sim targets, iceprog target)
# is implemented in Phase 1 / by the Integration agent.
#
# Target device: iCE40UP5K, package SG48 (iCEBreaker)
# VHDL standard: --std=93 (required for every ghdl -a/-e/-r invocation)

.PHONY: help build sim prog clean

help:
	@echo "wspr-icebreaker — build system not yet implemented (see Makefile header)."
	@echo "Planned targets: build (bitstream), sim (GHDL --std=93), prog (iceprog), clean"

build:
	@echo "ERROR: build flow not implemented yet (Phase 1)." && false

sim:
	@echo "ERROR: simulation flow not implemented yet (Phase 1)." && false

prog:
	@echo "ERROR: programming flow not implemented yet (Phase 1)." && false

clean:
	@echo "Nothing to clean yet."
