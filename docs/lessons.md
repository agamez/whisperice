# Lessons — the wspr-icebreaker teaching walkthrough (plan §33)

> The project is course material as much as a beacon (plan §1.3). This walkthrough follows the
> eleven lessons required by plan §33, in teaching order. Each lesson names the files to read, the
> testbench to run (`make sim TB=<name>`), and the observation to make — in a waveform viewer or
> in the TB's PASS report. Work top to bottom: every lesson only needs the ones before it.
>
> **Slide-course version:** `docs/course.html` — a self-contained HTML deck covering the same
> ground plus the underlying communication theory (sampling, aliasing, DDS, link budgets, filter
> design), with graphics, labs and references. Open it in any browser (arrows to navigate).
>
> Constants you will meet are all cited in [`docs/spec.md`](spec.md) and
> [`docs/protocol.md`](protocol.md); block contracts are in [`docs/architecture.md`](architecture.md)
> and [`docs/gps.md`](gps.md).

---

## Lesson 1 — GPIO and clocking

**Concept.** An FPGA design starts from a clock and a pin. There is no reset pin on the
iCEBreaker, so the design *generates* its own power-on reset, and everything else is a counter
dividing 12 MHz.

**Read.** `constraints/icebreaker.pcf` (every pin, with its official provenance);
`src/top.vhd` — the `por` process (16 cycles), the heartbeat process, the LED assignments.

**Run.** `make sim TB=tb_wspr_top` (the Phase-1 `tb_top` was retired — the integrated TB covers
POR/heartbeat).

**Observe.** `rst` high for exactly 16 cycles after configuration, then low forever; `led1`
toggling every 6,000,000 cycles (period 1 s: 0.5 s high, 0.5 s low); `led2` dark until the beacon
is ready (Lesson 9).

**Exercise.** Change `HEARTBEAT_DIV2` to make the heartbeat 2 Hz; explain why 3,000,000 is the
right number at 12 MHz (and why the constant, not the divider logic, is the thing to touch).

## Lesson 2 — counter and 1PPS

**Concept.** GPS receivers emit one pulse per second (1PPS). Everything time-related in this
design counts *clock cycles between 1PPS edges*. The subtlety is edge detection: the PmodGPS pulse
is ~100 ms long, so a level test would fire millions of times — you need a rising-edge detector.

**Read.** `src/gps/pps_measure.vhd` (the model lesson for comment quality: what is measured, the
reset-to-1 off-by-one, the 2-FF synchroniser, the timeout).

**Run.** `make sim TB=tb_pps_measure` — including its negative paths (missing pulse, long pulse).

**Observe.** A ~100 ms `pps_in` pulse producing exactly one single-cycle `pps_tick`; the falling
edge producing none; `measured_cycles_per_second` latching the interval count.

**Exercise.** Delete the synchroniser's second flip-flop in a scratch copy and explain which
physical effect (metastability) it guards against, and why the counter being off by one cycle once
per second does not matter after calibration (Lesson 3).

## Lesson 3 — frequency measurement

**Concept.** The onboard 12 MHz oscillator is *not trusted* (AGENTS.md rule 7). Each GPS second is
counted in FPGA cycles; the result is a frequency measurement with ±1 cycle of quantisation.
Averaging `CALIBRATION_SECONDS = 8` measurements reduces the standard error ≈ √N (the worst-case
bias stays below 1 cycle/s); bounds check the result; the value is then frozen for the duration of
a transmission and re-measured before the next one.

**Read.** `src/timing/clock_calibration.vhd` (averaging math, round-half-up, bounds, freeze).

**Run.** `make sim TB=tb_clock_calibration` — scenarios: valid average, out-of-bounds, PPS loss
mid-window.

**Observe.** The interval counter's reset-to-1 sawtooth; the average latching only after 8 valid
seconds; `calibration_error` + `calibration_frozen` asserted *together* on an out-of-bounds window
(the trap behind review finding M5); PPS loss invalidating an in-progress window.

**Exercise.** With a true clock of 12,000,100 Hz, which bounds parameter rejects it, and what
ppm error is that?

## Lesson 4 — NCO

**Concept.** A numerically-controlled oscillator is one adder: a big phase register, incremented
every clock, MSB to a pin. `f_out = I · f_clk / 2^40`. The wrap *is* the modulus — in `numeric_std`
the carry out of the fixed-width assignment is dropped. Above Nyquist the 1-bit output folds
(10.14 MHz carrier → apparent ≈1.86 MHz jittery pattern; the real content is an image for the
external filter to select).

**Read.** `src/nco/nco.vhd` (header first — the folding walkthrough is self-contained);
`tools/calculate_nco.py` (where every increment comes from).

**Run.** `make sim TB=tb_nco` — scenario [A] below Nyquist, scenario [B] the fold.

**Observe.** The accumulator staircase and the MSB square wave; period `2^40/I` clocks; in [B] the
apparent (folded) frequency matching `(2^40 − I)·f_clk/2^40`.

**Exercise.** Compute the increment for the 80 m WSPR dial frequency 3 568 600 Hz at exactly
12 MHz; how many LSBs of error does the nearest integer increment introduce, and is that below the
±0.4 ppm a decoder tolerates?

## Lesson 5 — FSK

**Concept.** Frequency-shift keying with *continuous phase*: one accumulator serves the whole
transmission, and each WSPR symbol only changes the *increment* — never the phase. Symbol timing
must be exact even when `f_clk·8192/12000` is not an integer, so lengths are distributed by a
Bresenham error term with no cumulative drift.

**Read.** `src/wspr/wspr_modulator.vhd` — the header (centered tone grid `inc(k) = CARRIER +
(2k−3)·HALF_TONE_INCREMENT`, precomputed `INC_T0..T3` to avoid a 130 ns multiplier) and the single
process (phase advance + symbol FSM + Bresenham).

**Run.** `make sim TB=tb_wspr_modulator` — Run A (timing), Run B (fractional exactness), Run C
(tone application + no-skew regression).

**Observe.** Phase continuity across a symbol boundary (the accumulator never resets mid-TX);
per-symbol lengths in {8192, 8193} but the 162-symbol total exact within 1 cycle; Run C's
per-symbol transition classes following the tone vector exactly (review finding M1's regression
test).

**Exercise.** Why does `symbol_latched` (not the live input) select the increment? What would a
mid-symbol increment change do to decoder sync?

## Lesson 6 — FEC

**Concept.** WSPR protects 50 payload bits with a rate-1/2 convolutional code (K=32): a 32-bit
state shift register, two polynomials, 81 input bits (50 + 31 zero tail) → 162 coded bits. Weak
signals survive because every bit is spread over many symbols.

**Read.** `src/wspr/wspr_fec.vhd`; polynomials in `docs/protocol.md` (pinned WSJT-X 2.7.0 source).

**Run.** `make sim TB=tb_wspr_fec` — golden 162/162 comparison.

**Observe.** The shift register consuming payload bits then 31 tail zeros; POLY1 parity always
first.

**Exercise.** Feed a payload with one flipped bit in a scratch model and count how many of the 162
output bits change (answer: about half — that is the point of the code).

## Lesson 7 — interleaving

**Concept.** The convolutional code bursts errors; the decoder tolerates *scattered* ones. WSPR
therefore interleaves with a fixed bit-reversal permutation — frozen, not "an equivalent
permutation", because the decoder assumes exactly this mapping.

**Read.** `src/wspr/wspr_interleave.vhd`; the algorithm in `docs/protocol.md`.

**Run.** `make sim TB=tb_wspr_interleave` — the permutation check and popcount invariant.

**Observe.** Input bit i appearing at output position j0(i); popcount preserved.

**Exercise.** Show that the interleaver is an involution (apply it twice → identity) for this
length, or explain why not.

## Lesson 8 — WSPR message

**Concept.** The whole protocol chain so far: `CALLSIGN GRID4 POWER` → 50-bit payload → 162 coded
bits → interleaved → combined with the 162-bit sync vector → 162 channel symbols (2 bits each,
`tone = 2*data + sync`), values 0..3. Sync symbols occupy known positions so a decoder can lock.

**Read.** `src/wspr/wspr_message.vhd` (Type-1 encoding: callsign packing, grid+power),
`src/wspr/wspr_sync.vhd`, `src/wspr/wspr_symbols.vhd`; the golden vector
`reference/test_vectors/k1abc_fn42_37.txt`; `reference/wspr_reference.py` (independent model).

**Run.** `make sim TB=tb_wspr_message` and `make sim TB=tb_wspr_symbols`; then
`python3 reference/wspr_reference.py --self-test` (cross-checked 0/162 against `wsprcode`).

**Observe.** Payload → coded → interleaved → tones for "K1ABC FN42 37" matching the golden vector
bit for bit.

**Exercise.** Bench messages like "K1ABC FN42 37" are simulation vectors only — never radiate an
example callsign (plan §25). Explain what a licensed operator must change in `top.vhd` to transmit
legally.

## Lesson 9 — GPS + synchronisation

**Concept.** WSPR transmissions start 1.000 s into an even UTC minute (spec §7). The beacon must
*know* UTC: NMEA RMC sentences carry the time-of-day, 1PPS carries the second boundary. 1PPS is
primary; NMEA only says *which* second it is. The scheduler then fires at `second = 1` of an even
minute — and only if calibration succeeded.

**Read.** `src/gps/gps_uart.vhd` (bit-centre sampling), `src/gps/gps_parser.vhd` (checksum-verified
RMC; commit-on-CRLF), `src/gps/gps_time.vhd`, `src/timing/wspr_scheduler.vhd` (the six-state FSM
and the edge-based calibration handshake).

**Run.** `make sim TB=tb_gps_uart`, `TB=tb_gps_parser`, `TB=tb_gps_time`, `TB=tb_wspr_scheduler`;
then the integration: `make sim TB=tb_wspr_top` — which since review finding M7 also checks the
**tone identity of all 162 transmitted symbols** against the golden vector (the check that would
have caught the M1 one-symbol skew).

**Observe.** UART sampling at bit centres; a corrupted checksum leaving committed outputs
unchanged; `pps_tick` advancing UTC once per second; `tx_enable` exactly at `minute_even &
second=1`; the ready LED dropping during every recalibration window (M5 semantics).

**Exercise.** Trace the handshake: why must `READY` be entered only on a *fresh* `cal_valid`
rising edge, and what stale-level bug does that prevent?

## Lesson 10 — SDR and waterfall

**Concept.** A WSPR signal is judged by how it *looks* in a spectrogram: 4 tones at
1.46484375 Hz spacing (12000/8192 Hz), 110.6 s long, drifting slowly. With a 1-bit output the
carrier must sit below Nyquist (6 MHz at 12 MHz) to be directly observable — hence 160 m/80 m for
first tests (see `architecture.md` §11).

**Read.** `docs/protocol.md` §8 (folding caveat), `docs/rf.md` (band table, tone-order rule,
filter requirements).

**Run.** `python3 tools/check_tone_order.py` — proves the tone-order rule of `rf.md` §1
numerically on the real increments (RF line correct, fold inverted, fold ~15 dB stronger).
*To do*: dump a simulated `rf_out` to WAV and plot its spectrum (`tools/inspect_wspr.py` —
placeholder).

**Observe.** (Planned) the four tone lines at the correct spacing; the fold for a >6 MHz carrier.

## Lesson 11 — remote reception / WSPRnet

**Concept.** The project's definition of success: a *standard* decoder (`wsprd` from WSJT-X 2.7.0)
decodes a real transmission and the spot appears on WSPRnet (plan §26, §38). Decoder DT ≈ 0
confirms the +1.000 s start offset; the decoded callsign/grid confirm the whole codec chain.

**Read.** `docs/spec.md` §7.3, `docs/protocol.md` §6; `docs/verification.md` (the adjudication
record).

**Run.**
`python3 tools/make_wspr_wav.py --start 1.0 --out /tmp/260101_0001.wav` then
`wsprd -v -f 10.140210 /tmp/260101_0001.wav` — the synthetic-WAV adjudication (§2 of
`docs/verification.md`). The on-air version of this lesson needs the board (PENDING-HARDWARE).

**Observe.** `wsprd` decodes "K1ABC FN42 37" with DT ≈ 0.0 for a TX placed at 1.000 s (the
frozen +1.000 s start, spec §7) and DT ≈ +1.0 when placed at 2.000 s.

---

**Status after the pedagogical review (2026-09-27):** Lessons 1–9 are fully walkable with
committed, passing testbenches (13/13 under `make sim`). Lessons 10–11 are walkable from the
written docs (`docs/rf.md`, `docs/verification.md`) and tools (`tools/check_tone_order.py`,
`tools/make_wspr_wav.py`); the on-air spot and the measured pin spectrum remain
PENDING-HARDWARE — tracked in `review-pedagogical.md` §7.
