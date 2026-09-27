# Scoping Decision Record — 002

> Re-run of the scoping decision per the trigger defined in
> [`scoping_decision_001.md`](scoping_decision_001.md), executed 2026-09-27 against repo state
> `b27ffac` (Phase 0 spec frozen + verified; Phase 1 build flow reproducible and verified).
> Decision record only.

## 1. Decision

**Escalate to the specialized structure** for the parallel stretch, per the trigger conditions:

- **≥2 blocks ready in parallel with no shared files: YES (five disjoint work packages).**
  - C — WSPR codec: `src/wspr/{wspr_message,wspr_fec,wspr_interleave,wspr_sync,wspr_symbols}.vhd`
    + their testbenches. Unblocked: spec is frozen (polys, sync vector, interleaver, packing).
  - D — NCO/modulator: `src/nco/nco.vhd`, `src/wspr/wspr_modulator.vhd`, `tools/calculate_nco.py`
    + testbenches. Unblocked: spec §6/§8/§9 has all constants.
  - B1 — PPS/calibration: `src/gps/pps_measure.vhd`, `src/timing/clock_calibration.vhd` + TBs
    (Phases 2–3). Unblocked: build flow exists; testbenches simulate, no hardware needed.
  - B2 — UART/time/scheduler: `src/gps/{gps_uart,gps_parser,gps_time}.vhd`,
    `src/timing/wspr_scheduler.vhd` + TBs (Phases 7–8). Unblocked: spec §7/§10/§11 frozen.
  - E — independent reference model: `reference/wspr_reference.py`,
    `reference/test_vectors/k1abc_fn42_37.txt` (Phases 16 vector groundwork). Unblocked; runs
    against the installed `wsprcode` (WSJT-X 2.7.0).
  - File sets are pairwise disjoint; agents B1/B2/C/D use **separate GHDL workdirs**
    (`build/ghdl_B1` etc.) so they cannot clobber each other's analysis libraries. **No agent
    touches `Makefile`** — extending it is integration work after the blocks land.
- **At least one block touches protocol-critical constants: YES** — C implements the frozen FEC
  polynomials, interleaver and sync vector.

Agent A (hardware) stays deferred (blocked on the physical board). Agent F (integration) and
Agent G (pedagogical review) activate after B1/B2/C/D land. Agent E's RTL-vs-reference
comparison activates as each RTL block lands.

## 2. Standing rules for the parallel stretch

- Plan §29 Rules 1–6 bind every agent (Rule 1: one agent per file; enforced via the disjoint
  file sets above).
- Separation of duties: each RTL agent validates its own blocks with its own testbenches, but
  the adversarial/verification pass on each block is a **distinct reviewer agent**; protocol-
  critical work (C) gets an explicitly adversarial review.
- Golden vectors: all agents cite `/usr/bin/wsprcode` / `wsprd` from the pinned **WSJT-X 2.7.0**
  (Debian `wsjtx 2.7.0+repack-1`) and `docs/spec.md`; the reference model (E) is written
  independently from the spec, not from WSJT-X code, and cross-checked against `wsprcode`.
- Orchestrator commits per block after its review passes; agents never commit.

## 3. Trigger for the next re-scope

After B1/B2/C/D/E land and are verified: re-scope at integration (Agent F: wire pps→
calibration→scheduler→codec→modulator→top, extend `Makefile`, `tb_wspr_top`), then Agent G's
full pedagogical pass before Phase 18+ hardware work.
