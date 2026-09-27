# AGENTS.md — Instructions for AI agents working on wspr-icebreaker

This file is the entry point for any AI agent (or careful human) working in this repository.
It tells you what this project is, which rules you must not break, and where the authoritative
documents live.

**Normative document:** [`doc/wspr_icebreaker_orchestrator_plan.md`](doc/wspr_icebreaker_orchestrator_plan.md).
When this file and the plan disagree, the plan wins. This file only summarizes and points.

---

## 1. What this project is

An autonomous, **protocol-compliant WSPR beacon** on the iCEBreaker board (Lattice iCE40UP5K)
plus a Digilent PmodGPS. All synthesized logic is **VHDL-93** and runs entirely in the FPGA —
no softcore CPU, no PC involvement at transmission time. The beacon reads UTC from GPS
(NMEA + 1PPS), calibrates its own 12 MHz clock against 1PPS before every transmission, and
emits continuous-phase 4-FSK (162 symbols, 110.592 s) from a single GPIO pin.

**Success is not "a signal that looks like WSPR"** — it is a standard decoder (WSJT-X / wsprd)
correctly decoding a real transmission, eventually producing a spot on WSPRnet (plan §26, §38).

---

## 2. Hard constraints (violating any of these is a failed task)

1. **VHDL-93 only.** No VHDL-2008/2019, no SystemVerilog, no Verilog in `src/` or `sim/`.
   Pass `--std=93` explicitly on every `ghdl -a`, `ghdl -e`, and `ghdl -r` invocation.
   Testbenches are also VHDL-93.
2. **Protocol correctness over everything.** Never implement a "WSPR-like" variant or an
   approximation. Every constant (FEC polynomials, sync vector, interleaver, tone spacing,
   symbol timing) must come from a cited, pinned source — never from memory or an unverified
   blog (plan §1.1, §14, §36).
3. **Pinned reference implementation: WSJT-X 2.7.0** (Debian package `wsjtx 2.7.0+repack-1`,
   binary `/usr/bin/wsprd`, source via `apt-get source wsjtx`). All protocol timing constants
   must be resolved against *this* build — especially the 1 s vs. 2 s TX-start offset flagged
   in plan §0.1/§37 — and cited in `docs/protocol.md`.
4. **Never invent pin assignments.** `constraints/icebreaker.pcf` must be filled only from the
   official iCEBreaker PCF/schematic (plan §3.1).
5. **No softcore, no external MCU, no DAC/I/Q, no Python in the TX path.** Python (with numpy)
   is allowed only for test vectors, reference models, and verification tooling (plan §1.2, §34).
6. **RF safety/legal:** example callsigns such as `K1ABC FN42 37` are bench/simulation vectors
   only — never radiate them. Over-the-air transmission requires a license and the operator's
   own callsign (plan §0.1, §25).
7. **Do not trust the oscillator.** The 12 MHz clock is measured against GPS 1PPS, recalibrated
   before every transmission, and frozen during a transmission (plan §1.4, §7).

---

## 3. Environment (already set up and verified)

Full details, versions and verification commands: **[`docs/environment.md`](docs/environment.md)**.
Toolchain (Debian 13, installed via apt, verified end-to-end on the UP5K):

| Purpose | Tool | Invocation notes |
|---|---|---|
| Synthesis | Yosys 0.52 | `synth_ice40` emits **`-json`** (nextpnr 0.7 has no BLIF input) |
| Place & route | nextpnr-ice40 0.7 | `--up5k --package sg48` |
| Bitstream / timing | icepack / icetime | `icetime -d up5k` |
| Programming | iceprog | board attaches as FT2232H `0403:6010`; udev rule installed; user in `plugdev` |
| Simulation | GHDL 5.0.1 | always with `--std=93` |
| Reference decoder | wsprd (WSJT-X 2.7.0) | `wsprd <file.wav\|file.c2>` |
| Reference model / tools | Python 3.13 + numpy 2.2.4 | no extra pip packages installed |

**Hardware status:** no iCEBreaker was attached during setup — `iceprog -t` has not been
exercised against real hardware yet. If you have the board, run `lsusb | grep -i 0403:6010`
then `iceprog -t` and record the result in `docs/environment.md`.

---

## 4. Repository layout and file ownership

Layout matches plan §27 exactly. **Many files are empty placeholders** from environment setup —
implementing them is the job of the phase agents, not housekeeping to delete:

```text
constraints/icebreaker.pcf    ← Agent A (official PCF values only)
src/top.vhd                   ← Phase 1 minimal top, later Agent F integration
src/clock|gps|timing|nco|wspr ← Agents B/D/C per plan §28
sim/tb_*.vhd                  ← one testbench per block (Rule 2: RTL + testbench + docs)
reference/wspr_reference.py   ← Agent E independent model
reference/test_vectors/       ← Agent C/E frozen vectors (e.g. k1abc_fn42_37.txt)
tools/*.py                    ← Agent D / Phase 5 helpers
docs/*.md                     ← each phase agent documents its block; architecture/protocol
                                are frozen in Phase 0 and change only with review
doc/                          ← pre-existing planning briefs (orchestrator plan, agent briefs);
                                do not edit without explicit instruction
```

---

## 5. Workflow rules (from plan §28–§29 — binding)

- **Rule 1:** one agent per file at a time; no concurrent edits to the same file.
- **Rule 2:** a block is not finished without **RTL + testbench + documentation**. "It
  synthesizes" is not done.
- **Rule 3:** every block needs a functional test, not just a successful build.
- **Rule 4:** do not silently fix another agent's bug — return it to the responsible agent.
- **Rule 5:** any change to a WSPR constant forces a re-review of the test vectors.
- **Rule 6:** no protocol approximations without explicit, documented justification.
- **Separation of duties:** the agent that implements a block must not be the one that
  pedagogically/adversarially reviews it (Agent E/G roles — see [`doc/setup_agents.md`](doc/setup_agents.md)).

### Agent roles (plan §28)

| Role | Scope |
|---|---|
| A — Hardware/docs | iCEBreaker + PmodGPS verification, PCF, electrical levels → `docs/hardware.md` |
| B — GPS/timing | UART, NMEA parser, PPS sync, measurement, calibration, UTC, scheduler |
| C — WSPR codec | Type 1 source encoding, FEC, interleaver, sync vector, symbols (protocol-critical, isolated) |
| D — NCO/modulator | NCO, increment math, continuous-phase 4-FSK, symbol timing, GPIO |
| E — Verification | Independent Python model, RTL-vs-reference comparison, tries to break the design |
| F — Integration | Makefile, constraints, bitstream, hardware testing; resolves interfaces only |
| G — Pedagogical review | Reviews everything as course material; may simplify working code |

### How agents are spawned

Per [`doc/setup_agents.md`](doc/setup_agents.md): default to a **single general-purpose
executor** for early sequential phases (Phase 0/1); escalate to the specialized A–G structure
only when ≥2 blocks can proceed in parallel with no shared files **and** at least one touches
protocol-critical constants. Re-scope after each phase. Never let one agent implement and
review the same block.

---

## 6. Build / verify commands (verified working on this host)

```sh
# Synthesis + P&R + bitstream (smoke-tested flow; real Makefile arrives in Phase 1)
yosys -q -p "read_verilog top.v; synth_ice40 -top top -json top.json"        # .vhd via ghdl-yosys bridge or read_vhdl as set up in Phase 1
nextpnr-ice40 --up5k --package sg48 --pcf constraints/icebreaker.pcf \
              --json top.json --asc top.asc --freq 12
icepack top.asc top.bin
icetime -d up5k top.asc

# Simulation — VHDL-93, always explicit
ghdl -a --std=93 src/nco/nco.vhd sim/tb_nco.vhd
ghdl -e --std=93 tb_nco
ghdl -r --std=93 tb_nco --assert-level=error

# Programming (requires attached board)
iceprog top.bin
```

Acceptance criteria per phase are in plan §30. `make clean && make` must produce a bitstream
error-free once the Phase 1 Makefile lands.

---

## 7. Practical rules for this repo

- **Git:** short imperative commit messages (existing style: "Add agents plan", "Set up
  development environment and repository skeleton"). Commit each completed unit of work.
- **No hidden magic numbers:** named constants with comments explaining provenance
  (e.g. `constant NOMINAL_CLOCK_HZ : integer := 12000000;` — plan §6).
- **Prefer one simple block** over cleverness; the code is teaching material (plan §1.3, §33).
- **Simulation time:** do not simulate 120 s at 12 MHz; make test times configurable and scale
  test parameters only, never the functional logic (plan §21).
- **Failure behavior** (plan §31) is part of the design: no GPS → no TX; PPS loss → invalidate
  calibration; reset during TX → RF off immediately. Do not treat these as error handling to
  add "later".
- **When you finish a phase,** update the relevant `docs/*.md` and this file if the workflow
  rules change — but keep changes to `doc/` (plural vs. singular distinction above) minimal.
