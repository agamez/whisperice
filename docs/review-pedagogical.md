# Pedagogical review — wspr-icebreaker

> **Agent G review (plan §28, §33, §1.3)** performed 2026-09-27 on the repository at commit
> `0279a29`, plus a "fresh-student" blind read of `src/nco/nco.vhd`. This document is the review
> deliverable: what was checked, what was found, and how each finding was resolved. All findings
> below were triaged and (where accepted) fixed and re-verified; the resolution status is marked
> inline so the document also serves as a change log of the review.

## 1. Method

Three independent passes:

1. **Full review sweep** (Agent G role): every file in `src/`, all `sim/*.vhd` testbenches,
   `Makefile`, `constraints/icebreaker.pcf`, and `docs/{spec,architecture,protocol,gps,environment}.md`,
   checked against the course-material goal (plan §1.3: a student can open `wspr_fec.vhd`,
   `nco.vhd` or `pps_measure.vhd` and understand what is happening): understandability, naming,
   magic numbers, block responsibility, comments, abstraction level, VHDL-93 strictness
   (`ghdl -a --std=93 -fexplicit -Wbinding` on all sources), and docs-vs-RTL consistency.
   The reviewer also **ran** the toolchain: `make sim`, `make build`, `wspr_reference.py
   --self-test`, `tools/calculate_nco.py`, and a scratch simulation of the real scheduler +
   modulator handshake.
2. **Fresh-student blind read**: a reviewer given *only* `src/nco/nco.vhd` (no other file, no
   docs) and asked to explain the block and list every confusion (§4).
3. **Triage and fix**: each finding accepted/adjusted and applied by the integrator, then the
   full suite re-run. Per the separation-of-duties rule the reviewer did not modify tracked files.

## 2. Verification performed during the review (as-found state @ `0279a29`)

| Check | Result |
|---|---|
| `ghdl -a --std=93 -fexplicit -Wbinding` on all 15 `src/` files | 14/14 rc=0; `clock_control.vhd` is 0 bytes |
| same on all 14 `sim/*.vhd` | 13/14 rc=0; **`tb_top.vhd` rc=1** (stale Phase-1 generics/ports) |
| grep sweep `process(all)`, `std.env`, `context`, `protected`, views | none in code (only "we do not use" disclaimers) |
| `make sim` | PASS 12/12 configured TBs |
| `tb_wspr_scheduler` run manually | PASS — **but it was not in `SIM_TBS`** (M3) |
| `make build` (Yosys→nextpnr→icepack→icetime) | PASS, 30.15 MHz |
| `python3 reference/wspr_reference.py --self-test` | ALL CHECKS PASSED (0/162 vs `wsprcode`) |
| `python3 tools/calculate_nco.py` | half-spacing increment 67109 ✓ |
| scratch scheduler↔modulator handshake sim | **revealed critical off-by-one (M1)** |

## 3. Findings and resolutions

### MUST-FIX (all resolved)

**M1 — CRITICAL: the scheduler↔modulator symbol index was skewed by one symbol; the
over-the-air tone sequence was wrong.**
`wspr_modulator.vhd` latched `symbol_index` at the boundary edge **B**, but `symbol_tick` is
registered, so the scheduler only incremented its counter at **B+1** — the modulator always latched
the *previous* index. The transmitted sequence was `(0, 0, 1, 2, …, 160)` instead of `(0, 1, …,
161)`: symbol 0's tone repeated, every later tone one symbol early, channel symbol 161 never sent.
This would have defeated the primary success criterion (standard-decoder decode, plan §26/§30).
*Why it slipped*: `tb_wspr_top` checked timing/counts only, never tone identity; the modulator TB
drove `symbol_index` by hand, so it never exercised the handshake.
**Resolution (structural)**: the modulator now **owns the symbol counter** and takes the full tone
vector `tones(0 to 2*SYMBOLS_PER_TX-1)`; the external index mux in `top.vhd` was deleted (a
scheduler-driven index can no longer be misaligned — the skew is structurally impossible). The
scheduler's internal counter now only counts ticks to detect the end of TX.
**New regression checks**: `tb_wspr_modulator` Run C drives a tone vector that changes at symbol 6
and verifies per-symbol transition classes (a skew would shift them); `tb_wspr_top` gained the
**tone-identity check** (M7): all 162 observed per-symbol rising-edge counts must match
`TONE_GOLDEN(k)` from the wsprcode golden vector. Post-fix integration run: transitions 679,935 vs
679,936 expected, all 162 classes match.

**M2 — `sim/tb_top.vhd` was a stale, non-compiling Phase-1 leftover.** rc=1 (`CLK_HZ` generic no
longer exists; `uart_rx`/`pps` unconnected), hidden by its absence from `SIM_TBS`.
**Resolution**: deleted (superseded by `tb_wspr_top`, which covers POR/heartbeat/LEDs of the real
top).

**M3 — `Makefile` `SIM_TBS` omitted the committed, passing `tb_wspr_scheduler`.**
**Resolution**: added; the stale "authored separately, may not exist" comment removed. `make sim`
now runs 13 TBs.

**M4 — `docs/architecture.md` was substantially stale and contradicted the RTL.** It still
documented `TONE_INCREMENT = 134217` with the non-centered grid (the exact mistake an implementer
would re-introduce), described `top.vhd` as Phase-1 LED bring-up, claimed `tb_wspr_top` was an empty
placeholder, and reported `tb_top` passing. **Resolution**: §2 (diagram), §4.2, §4.6, §6.1, §7,
§10, §12 rewritten to match the committed RTL (centered grid `CARRIER + (2k−3)·HALF`,
modulator-owned symbol index, integrated top, real PCF, 13 TBs).

**M5 — the ready LED (`led2`) was lit during a calibration error.** `ready <= utc_valid and
cal_frozen`, but `clock_calibration` asserts `frozen` **and** `error` together on an out-of-bounds
window. **Resolution**: `ready <= utc_valid and cal_valid` (`cal_valid` is cleared at the start of
every recalibration window and stays low on error); comments and TB header updated.

**M6 — stale "empty placeholders" claims** in `README.md` and `docs/environment.md` §5 would
mislead a student opening the repo. **Resolution**: both updated; the genuinely empty files are
listed explicitly (`src/clock/clock_control.vhd`, `tools/inspect_wspr.py`, `docs/rf.md`,
`docs/verification.md`, `docs/lab.md`).

**M7 — the integration test never checked symbol content.** **Resolution**: `tb_wspr_top` now
derives each symbol's tone class from its rising-edge count (scaled NCO: exactly `8·increment`
rising edges per 8192-cycle symbol) and compares all 162 against `TONE_GOLDEN` (§3, M1). The total
transition count is also checked exactly (±4) against the golden-vector sum.

### SUGGESTED (all resolved)

- **S1** `clock_calibration.vhd` averaging claim: averaging reduces the *standard error* by ≈√N;
  the worst-case quantisation bias stays below 1 cycle/s. Header reworded.
- **S2** `gps_parser.vhd`: the `type_char()` indirection removed (`'R'`,`'M'`,`'C'` written
  literally); the `addr3` slide comment now states the delta-cycle semantics explicitly ("the two
  characters received before `ch`").
- **S3** `wspr_scheduler.vhd`: the `if utc_valid='0' then null` no-op replaced by a plain comment
  carrying the same design decision.
- **S4** `top.vhd`: provenance comment added for `HALF_TONE_INCREMENT = 67109`.
- **S5** `wspr_modulator.vhd`: function formals renamed `clock_hz` → `f_clk` (no more `-Whide`);
  worked example added (CLOCK_HZ = 12001 → REM = 8192, lengths 8192/8193, exact total).
- **S6** `top.vhd`: explicit note at `u_cal` that v1 validates/freezes `cal_hz` but the
  calibrated→increment datapath is not wired (increments are build-time generics, spec §9).
- **S7** missing teaching material: `docs/lessons.md` written (plan §33 walkthrough, 11 lessons);
  Lessons 10–11 artifacts (`docs/rf.md`, captured WAV, `docs/verification.md`) remain open.
- **S8** `gps_parser.vhd`: `ST_COMMIT` re-arms on `$` so a stream without CRLF does not swallow the
  next sentence.
- **S9** PPS-loss-after-window semantics documented (architecture §9 matrix): a *completed*
  calibration stays valid; invalidation applies to windows in progress; the scheduler re-enters
  READY only on a fresh `cal_valid` edge. (Gating change deliberately deferred — behaviour is
  defensible and documented.)
- **S10** `top.vhd` heartbeat comment corrected (period 1 s: 0.5 s high, 0.5 s low).

### COSMETIC (resolved)

`tb_wspr_top` header edge-count wording fixed; architecture "13 non-empty testbenches" corrected to
the real 13-run suite; Makefile comment de-staled. `wspr_symbols.vhd`'s four-branch tone case was
reviewed and **left as is** (clearly commented; a slice-assignment rewrite adds no clarity).

## 4. Fresh-student blind read of `nco.vhd`

The blind reader reconstructed the accumulator/MSB principle fully and correctly on the first pass
("the core datapath is about 10 lines and I understood it fully"), and confirmed the header's
honesty about folding. Confusions raised, and what was done:

| # | Confusion | Action |
|---|---|---|
| 1 | `NOMINAL_CLOCK_HZ` declared and never used | Constant removed; the provenance moved into a comment |
| 2 | Nyquist paragraph assumed aliasing knowledge and deferred the real carrier's behaviour to files the reader "doesn't have" | Header now walks the mechanism and a worked example (10.14 MHz → apparent ≈1.86 MHz jittery pattern; image selected by external filter) |
| 3 | "30 m" unexplained | Ham-band gloss added ("30 m", ~10 MHz) |
| 4 | Citations load-bearing; 1.46484375 Hz asserted without derivation | Derivation added (12000/8192 Hz: one symbol lasts 8192/12000 s) |
| 5 | `increment` is `std_logic_vector` while the accumulator is `unsigned` | House convention documented at the port |
| 6 | "wraps naturally" hides the mechanism | Comment states the numeric_std truncation rule (carry dropped = the modulus) |
| 7 | ±1 clock of edge jitter never mentioned | Documented (frequency law exact in the average; harmless over a symbol) |
| 8 | "MSB is the sign" (it is `unsigned`) and a bare `N` | Reworded to the unsigned half-range split; `N` spelled out |
| 9 | Who drives `increment` at runtime? | Header states the modulator drives it once per symbol; the block is modulation-agnostic |
| 10 | Is declaration-time init trustworthy on silicon? | Header notes top.vhd's POR guarantees a defined start |
| 11 | "hundreds of thousands of LSBs" inflated | Corrected to ≈134,000 |

Reader's verdict: reuse confidently; the one change that would most improve it (self-contained
folding explanation) is applied. Questions 4 (does a receiver care about jitter), 7 (why not 32
bits) and 8 (port typing) remain good seminar material; the frozen-40-bit decision is cited to
plan §8 and not re-litigated in RTL.

## 5. What is pedagogically strong (do not "fix" away)

- **Comment density and provenance**: every block header names purpose, plan/spec section, and the
  pinned WSJT-X 2.7.0 `file:line` for protocol constants; "no hidden magic numbers" is genuinely
  honoured.
- **`pps_measure.vhd` is the model lesson**: what is measured, the reset-to-1 off-by-one, long-pulse
  edge detection, counter-width margin, timeout.
- **The centered-grid rationale is honest** (`tools/calculate_nco.py` prints the exact increments;
  the modulator header explains the +1-LSB spacing and the 130 ns multiplier that motivated
  precomputed `INC_T0..T3`).
- **Codec separation is clean and golden-verified** (`wspr_message → fec → interleave → sync →
  symbols`, cross-checked 0/162 against `wsprcode` and by an independent Python model).
- **The Nyquist limitation is documented, not hidden**, in RTL, TBs and docs.
- **Failure behaviour is first-class** and exercised by TBs (no UTC → no TX, out-of-bounds → error,
  reset → RF off, corrupt NMEA → outputs retained).
- **`tb_wspr_modulator` Run B** (fractional-symbol accumulator) and the negative-path TBs
  (`tb_pps_measure`, `tb_clock_calibration`) are unusually strong functional tests.

## 6. Post-fix verification

| Check | Result |
|---|---|
| `make sim` (13 TBs incl. `tb_wspr_scheduler`) | 13/13 PASS |
| `tb_wspr_top` tone identity (M7/M1 regression) | all 162 symbol classes match `TONE_GOLDEN`; total transitions 679,935 vs 679,936 expected |
| `make build` | PASS, icetime 31.09 MHz (≥ 12 MHz requirement) |
| docs | `architecture.md`, `README.md`, `environment.md` de-staled; `lessons.md` added |

## 7. Still open

- Lessons 10–11 artifacts: `docs/rf.md` (band selection), a captured/simulated WAV + `wsprd`
  adjudication record (`docs/verification.md`), `tools/inspect_wspr.py`, `docs/lab.md`.
- Hardware bring-up (PENDING-HARDWARE, spec §16): `iceprog -t` has never run against a board.
- v1 gap (documented, deliberate): calibrated `cal_hz` is validated/frozen but the modulator
  increments are build-time constants (S6/§8 of `architecture.md`).
