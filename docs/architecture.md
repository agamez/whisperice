# System architecture — wspr-icebreaker

> **Frozen architecture description.** Grounded entirely in [`docs/spec.md`](spec.md) (frozen
> constants), the orchestrator plan [`doc/wspr_icebreaker_orchestrator_plan.md`](../doc/wspr_icebreaker_orchestrator_plan.md)
> §2, §4–§26, §27, §31, §32, [`docs/gps.md`](gps.md), [`docs/environment.md`](environment.md) and the
> committed RTL file headers. Protocol constants live in [`docs/protocol.md`](protocol.md).

## 1. Purpose

An autonomous, protocol-compliant WSPR beacon implemented entirely as VHDL-93 FPGA logic on an
iCEBreaker (Lattice iCE40UP5K, SG48) with a Digilent PmodGPS (rev. A). There is **no softcore, no
external MCU, no DAC, no I/Q path and no Python in the transmit path** (`AGENTS.md` §2.5; plan §1.2,
§18, §34). It reads UTC from GPS, measures its 12 MHz clock against GPS 1PPS, recalibrates before
every transmission, and emits continuous-phase 4-FSK from one GPIO pin. Success is a standard decoder
(WSJT-X/`wsprd`) decoding a real transmission (plan §26, §38). All blocks are VHDL-93 (IEEE Std
1076-1993), simulated with `ghdl --std=93` (`docs/environment.md` §3.2; `AGENTS.md` §2.1).

## 2. System block diagram

```text
      PmodGPS rev. A (9600 8N1, spec §10)              iCEBreaker / iCE40UP5K
    ┌───────────────────────┐
    │  NMEA UART TX ─────────┼──► gps_uart ──► gps_parser ──► gps_time ──────────────┐
    │  1PPS ─────────────────┼──► pps_measure ──► pps_tick ──┘                      │
    └───────────────────────┘        │                                             ▼
                                measured_cycles_per_second              utc_valid, hour/min/sec,
                                     │                                   minute_even   (spec §7)
                                     ▼                                             │
                            clock_calibration ── calibrated_clock_hz ───────────────┤
                                     ▲                                             │
                     cal_start / cal_valid / cal_error                             │
                                     └──────────────────── wspr_scheduler ──────────┘
                                                                │  tx_enable
                                                                ▼
 wspr_message ─► wspr_fec ─► wspr_interleave ─► wspr_symbols ─► (162 × 2-bit tones)
      ▲                                                                  │
 CALLSIGN GRID4 POWER_dBm
                                                                        │
                                                         ▼
                                            wspr_modulator  (ONE phase accumulator,
                                              owns the symbol counter and indexes
                                              the tone vector itself -- review
                                              finding M1; continuous-phase 4-FSK)
                                                                        │
                                  external LPF/BPF + optional PA ──► antenna (plan §19)

 diagnostics: LEDs (LEDR_N pin 11, LEDG_N pin 37) + scheduler state_o + internal signals in
              simulation (plan §32; spec §13)
```

## 3. Clocking

One clock domain: the board's **12 MHz onboard oscillator**, `NOMINAL_CLOCK_HZ = 12000000` (spec §8;
plan §3.1, §6), shared with the FT2232H. Pin `clk` = 35. `src/clock/clock_control.vhd` is a 0-byte
placeholder and is not instantiated in v1: the design runs directly from the oscillator and does not
use the UP5K PLL. The clock is never assumed exact — it is measured against 1PPS and averaged before
each transmission (§8).

## 4. GPS / timing chain blocks
### 4.1 `src/gps/gps_uart.vhd`
UART receiver for the PmodGPS NMEA link. Generics `CLOCK_HZ = 12_000_000`, `BAUD_RATE = 9600` (the
PmodGPS default 9600 8N1, spec §10). A 2-FF synchroniser brings RX into the clock domain; the start
bit is confirmed at its centre, data bits are sampled at their centres (LSB first), and the stop bit
must be high or a one-cycle `framing_error` is raised and the byte discarded. Bit period =
`CLOCK_HZ/BAUD_RATE` (1250 cycles at 12 MHz). Outputs `data(7:0)`, `data_valid`, `framing_error`. No
FIFO/overrun path: a dropped byte merely aborts one sentence (plan §31 safe).
### 4.2 `src/gps/gps_parser.vhd`
Minimal parser accepting only `$--RMC` (the address field is matched literally on the characters
`'R'`,`'M'`,`'C'`). It commits only if the XOR checksum
between `$` and `*` matches, the address ends in RMC, field 2 carried exactly six digits forming a
valid `hh:mm:ss`, and field 3 status is `A`. Outputs `time_strobe`, `hour`, `minute`, `second`,
`fix_valid`, `sentence_error` and `fix_warning` (checksum-valid RMC with status `V` = fix lost).
Rejected sentences never change committed outputs (spec §12; plan §31). A `$` that arrives directly
after the checksum (stream without CRLF) re-arms the parser immediately instead of being swallowed.
RMC presence is
PENDING-HARDWARE (spec §16). NMEA arrival time is never a time reference (plan §11).
### 4.3 `src/gps/gps_time.vhd`
UTC timekeeping disciplined by 1PPS. **1PPS is primary**: `pps_tick` advances one second; a committed
NMEA sentence only says *which* second it is and is applied immediately. `utc_valid` rises on the
first load and drops on `fix_warning` or reset. Handles s/m/h rollovers. `minute_even` = `valid AND
(minute mod 2 = 0)`, high for the whole even UTC minute; the scheduler fires at `second = 1` inside
it (spec §7; plan §11).
### 4.4 `src/gps/pps_measure.vhd`
1PPS conditioning and FPGA-clock measurement (plan §6). Generic `COUNT_WIDTH = 25` (holds 33,554,431 >
12,000,000); `TIMEOUT_CYCLES = 24_000_000` (two GPS seconds). A 2-FF synchroniser and rising-edge
detector produce one-cycle `pps_tick`; the ~100 ms PmodGPS pulse is edge-detected, never
level-sampled. The interval counter is re-armed to 1 so the value latched on each PPS is exactly the
number of FPGA clocks in the completed GPS second — the block measures **the FPGA clock against the
GPS second, not the reverse**. `measurement_valid` clears after `TIMEOUT_CYCLES` without an edge
(PPS lost → invalidate calibration, spec §12/plan §31).
### 4.5 `src/timing/clock_calibration.vhd`
Averages `CALIBRATION_SECONDS = 8` (configurable, spec §8; plan §7) valid per-second measurements with
round-half-up into `calibrated_clock_hz`, sets `calibration_frozen`, and holds the value until the
next `start` rising edge. Bounds `CAL_MIN_HZ`/`CAL_MAX_HZ` default to ±1000 ppm about 12 MHz
(DEFAULT-CONFIGURABLE; spec §8 freezes no tolerance); out-of-bounds sets `calibration_error='1'`,
`calibration_valid='0'` (do not transmit). PPS loss mid-window invalidates. `cal_valid`/`cal_error`
are levels that persist after the window, so consumers act on edges.
### 4.6 `src/timing/wspr_scheduler.vhd`
Slot scheduler, FSM `WAIT_GPS → CALIBRATE → READY → WAIT_SLOT → TX → TX_DONE` (`state_o` = 0..5). It
fires TX when `minute_even='1'` **and** `second=1` (spec §7: +1.000 s into the even UTC minute)
**and** `slot_mask(minute/2)='1'` (`slot_mask(0 to 29)`, default all-ones; plan §12). `tx_enable` is a
1-cycle pulse into `wspr_modulator.tx_start`. The scheduler counts `symbol_tick` internally to detect
the end of the transmission (162 ticks), but the **modulator owns the symbol index** and selects tones
from the codec vector itself (review finding M1: an external scheduler-driven index was skewed by one
symbol; see §6.1). The calibration handshake
is edge-based: `READY` only on a fresh `cal_valid` rising edge; `cal_error` re-pulses `cal_start`.
`TX_DONE` returns to `CALIBRATE`, so every transmission is preceded by a fresh calibration (plan §7).

## 5. WSPR codec blocks

All constants and primary WSJT-X 2.7.0 citations are in [`docs/protocol.md`](protocol.md) (spec §2–§5).

- **`src/wspr/wspr_message.vhd`** — Type-1 source encoding only: `CALLSIGN GRID4 POWER` → 50 bits
  (28 callsign + 15 grid + 7 power), including 6-character callsign padding/alignment and grid+power
  packing (spec §2). Exposes `n_value`/`m_value`; `payload(0)` is the first transmitted bit (MSB-first).
- **`src/wspr/wspr_fec.vhd`** — K=32, rate-1/2 Layland–Lushbaugh encoder: 50 payload + 31 zero tail
  bits = 81 input bits → 162 coded bits; `POLY1 = x"F2D05351"`, `POLY2 = x"E4613C47"` (spec §3). State
  is a 32-bit shift register, newest bit in the LSB; POLY1 parity emitted first, then POLY2.
- **`src/wspr/wspr_interleave.vhd`** — frozen bit-reversal interleaver `itmp[j0(i)] = id(i)` computed
  by the exact reference algorithm (spec §4), not an "equivalent" permutation.
- **`src/wspr/wspr_sync.vhd`** — owns the frozen 162-bit synchronisation vector as one named constant.
- **`src/wspr/wspr_symbols.vhd`** — explicit `tone_symbol = 2*data_bit + sync_bit` → {0,1,2,3} stored
  as 162 2-bit fields (spec §5); instantiates `wspr_sync`.
- **Verification anchor:** `reference/wspr_reference.py` is an independent Python model; its golden
  vector `reference/test_vectors/k1abc_fn42_37.txt` is cross-checked at **0/162 channel symbols**
  against `/usr/bin/wsprcode` (WSJT-X 2.7.0, `reference/README.md`).

## 6. Modulator and NCO blocks
### 6.1 `src/wspr/wspr_modulator.vhd`
Continuous-phase 4-FSK modulator (plan §10, §17). Generics `CLOCK_HZ = 12_000_000`,
`CARRIER_INCREMENT = x"D8530323E9"`, `HALF_TONE_INCREMENT = 67109`, `SYMBOLS_PER_TX = 162`,
`ACCUMULATOR_BITS = 40`. **One shared phase accumulator** serves the whole transmission, so phase is
continuous across symbol boundaries. The modulator **owns the symbol counter**: it takes the full
162-entry tone vector `tones(0 to 323)` (2 bits per symbol: field `2k` = sync, `2k+1` = data) and, at
each symbol boundary, advances to the next symbol and selects that symbol's increment **in the same
clock cycle**. The per-symbol increments realize the centered tone grid of spec §6:

    inc(k) = CARRIER_INCREMENT + (2k − 3) · HALF_TONE_INCREMENT      (k = 0..3)

precomputed as constants `INC_T0..T3` (a runtime multiplier would cost ~130 ns at 12 MHz).
`HALF_TONE_INCREMENT = 67109` is exactly half the rounded tone-spacing increment (12000/8192 Hz);
`2·67109 = 134218` differs from the single-step increment `134217` by +1 LSB ≈ 1.1e-5 Hz
(`tools/calculate_nco.py`, `wspr_modulator.vhd` header). Symbol timing uses an exact fractional split
`cycles_per_symbol = CLOCK_HZ * 8192 / 12000`
with Bresenham floor distribution, so the cumulative length of N symbols is exactly
`floor(N * CLOCK_HZ * 8192 / 12000)` cycles (≤ 1 cycle error over all 162 symbols — no cumulative
rounding, plan §10). Outputs `rf_out` (MSB), `tx_active`, `symbol_tick`; reset clears the accumulator
and forces RF off (spec §12/plan §31). Increment provenance: `tools/calculate_nco.py` (spec §9).
The top level passes `ACCUMULATOR_BITS`/`CARRIER_INCREMENT`/`HALF_TONE_INCREMENT` through so
testbenches can scale them (plan §21).
### 6.2 `src/nco/nco.vhd`
Standalone 40-bit phase-accumulator NCO (Phase 4, spec §8): `f_out = increment * f_clk / 2**40`,
resolution ≈ 1.0914e-5 Hz at 12 MHz; `rf_out` is the accumulator MSB (1-bit square wave, no sine
table). It contains no frequency constant. The transmit path's symbol timing and tone offset are in
the modulator (§6.1), which embeds the same accumulator principle plus the symbol FSM.

## 7. Top level and integration

`src/top.vhd` **is** the integration point and integrates the full chain: POR (16-cycle power-on
reset), GPS/UART chain (`gps_uart → gps_parser → gps_time`), `pps_measure` + `clock_calibration`,
`wspr_scheduler`, the codec chain (`wspr_message → fec → interleave → symbols`), `wspr_modulator`
and the diagnostic LEDs. Pin assignments come only from `constraints/icebreaker.pcf` (never invented;
`AGENTS.md` §2.4, spec §11): `clk` 35, `led1` 11 (LEDR_N), `led2` 37 (LEDG_N), `uart_rx` 47
(PmodGPS TX), `pps` 45 (1PPS), `rf_out` 28 (P1B10). The bench message is frozen to
"K1ABC FN42 37" (spec §2; simulation/bench use only — plan §25). All generics are pass-throughs
so testbenches can scale parameters without changing the functional logic (plan §21).
Integration test: `sim/tb_wspr_top.vhd` (scaled CLOCK_HZ/BAUD/CALIBRATION_SECONDS/NCO, checks slot
timing, window length, total transitions and — since review finding M7 — the tone identity of all
162 symbols against the golden vector).

## 8. Clock-calibration loop

Requirement (plan §1.4, §7, §24; spec §8): measure the FPGA clock against 1PPS, average, freeze for
the duration of a transmission, recalibrate before every transmission.

Chain: `GPS 1PPS → pps_measure (measured_cycles_per_second, cycles per GPS second) →
clock_calibration (average CALIBRATION_SECONDS = 8, round-half-up, ±1000 ppm bounds) →
calibrated_clock_hz + calibration_frozen`, then the scheduler's edge-based handshake
(`cal_valid`/`cal_error`/`cal_start`) feeds the NCO/modulator phase increment, held constant during TX.

Status (v1): `calibrated_clock_hz` is produced, validated and frozen in RTL, but the increment value
itself is computed from it off-chip at build time by `tools/calculate_nco.py` (the modulator takes
`CARRIER_INCREMENT`/`CLOCK_HZ` as generics). A calibrated → increment datapath in RTL is not yet
wired (§12).

No dynamic retune during a transmission in v1 (plan §24): the accumulator is never cleared mid-TX,
only at `tx_start` (phase restarts because RF is off before/after).

## 9. Failure-behavior matrix

From plan §31 / spec §12 (binding), mapped to the implementing blocks. **No GPS → no TX** is the
governing rule.

| Condition | Required behaviour | Implementing block(s) |
|---|---|---|
| No GPS | NO TX | `gps_time.utc_valid='0'` → `wspr_scheduler` stays in `WAIT_GPS` |
| GPS loses fix | Do not start a new transmission until a valid reference returns | `gps_parser.fix_warning` (RMC status `V`) → `gps_time` drops `utc_valid` → `WAIT_GPS`; a TX already in progress runs to completion (documented decision; a mid-TX RF cut is rejected) |
| PPS disappears | Invalidate calibration | `pps_measure.measurement_valid='0'` after `TIMEOUT_CYCLES`; `clock_calibration` abandons/invalidates **a window in progress**. Documented v1 semantics (review finding S9): after a window has *completed*, `calibration_valid` persists even if the PPS later disappears — the measurement was validly taken, and the scheduler only re-enters `READY` on a fresh `cal_valid` edge after the next successful calibration. The scheduler does not re-check `cal_valid`/`measurement_valid` while idling in `WAIT_SLOT`. |
| Corrupt NMEA | Do not change the existing valid time | `gps_parser` rejects and retains committed outputs (`sentence_error`) |
| Measured frequency out of bounds | Error state, do not transmit | `clock_calibration.calibration_error='1'`, `calibration_valid='0'`; scheduler retries calibration |
| Invalid PLL/clock | Do not transmit | No PLL in v1; calibration bounds gate an implausible clock; no TX without a fresh valid calibration |
| Reset during TX | RF off immediately | `wspr_modulator` reset clears `active_r`/`rf_r` (`rf_out='0'`); scheduler → `WAIT_GPS` |

## 10. Diagnostics and observability

Plan §32 / spec §13 require observability without a CPU. Current access points:

- **LEDs.** `top` drives the two onboard user LEDs active-low: `led1` = LEDR_N (pin 11) is the
  **heartbeat** (period 1 s: 0.5 s high, 0.5 s low — the 12 MHz clock and POR are alive); `led2` =
  LEDG_N (pin 37) is the **ready indicator**: lit while `utc_valid AND calibration_valid`
  (dark during every recalibration window and on a calibration error — review finding M5).
- **Scheduler state.** `wspr_scheduler.state_o` (0..5) = `WAIT_GPS`, `CALIBRATE`, `READY`,
  `WAIT_SLOT`, `TX`, `TX_DONE`.
- **Internal signals in simulation** (named, no hidden magic numbers, plan §6): `gps_uart.data/
  data_valid/framing_error`; `gps_parser.hour/minute/second/fix_valid/sentence_error/fix_warning`;
  `gps_time.utc_valid/minute_even`; `pps_measure.measured_cycles_per_second/measurement_valid`;
  `clock_calibration.calibrated_clock_hz/calibration_valid/calibration_error/calibration_frozen`;
  `wspr_scheduler.tx_enable/symbol_index/state_o`; `wspr_modulator.tx_active/symbol_tick/rf_out`;
  codec `n_value/m_value/payload/coded/tones`.
- **UART (FTDI pins 6/9).** Listed in spec §11/§13 as a preferred diagnostic channel, but v1 has no RTL
  UART transmitter/telemetry stream. Pending.

## 11. RF output and the Nyquist constraint

The final output is exactly one bit (`rf_out : out std_logic`; plan §18) from a phase-accumulator NCO:
one shared phase word, MSB → GPIO, continuous phase, no DAC/I-Q/PWM. The pin is sampled at `f_clk`, so
the highest fundamental a 1-bit output can represent is `f_clk/2 = 6 MHz` at 12 MHz. The default 30 m
carrier `DEFAULT_RF_FREQUENCY_HZ = 10140200` (spec §9) is above Nyquist: its increment exceeds 2^39,
so the MSB pattern folds and the observable fundamental is `(2^40 − I)·f_clk/2^40 = 12 MHz −
10.1402 MHz ≈ 1.86 MHz` (`nco.vhd`/`wspr_modulator.vhd` headers). The phase arithmetic is exact; this
is a sampled-output property, not a logic defect.

Band implication: carriers below 6 MHz are directly representable. WSPR **160 m (1 836.6 kHz) and
80 m (3 568.6 kHz)** are the suitable initial test bands (spec §9). **40 m (7 038.6 kHz) and higher
are not directly representable at a 12 MHz sample rate** and need a faster output stage (higher sample
clock/SERDES or an external mixer/filter chain). Filtering/harmonics are external hardware (plan §19),
flagged for [`docs/rf.md`](rf.md) (currently a 0-byte placeholder).

## 12. Current implementation status

**Implemented end-to-end, with committed testbenches passing under `make sim`** (re-verified after
the 2026-09-27 pedagogical review; 13/13 testbenches pass, `make build` produces `build/top.bin` with
icetime PASS at ≥ 30 MHz):

| Area | Blocks | Testbenches |
|---|---|---|
| GPS / timing | `gps_uart`, `gps_parser`, `gps_time`, `pps_measure`, `clock_calibration`, `wspr_scheduler` | `tb_gps_uart`, `tb_gps_parser`, `tb_gps_time`, `tb_pps_measure`, `tb_clock_calibration`, `tb_wspr_scheduler` |
| Codec | `wspr_message`, `wspr_fec`, `wspr_interleave`, `wspr_sync`, `wspr_symbols` | `tb_wspr_message`, `tb_wspr_fec`, `tb_wspr_interleave`, `tb_wspr_symbols` |
| NCO / modulator | `nco`, `wspr_modulator` | `tb_nco`, `tb_wspr_modulator` |
| Integration | `top` (full chain + POR + LEDs) | `tb_wspr_top` (incl. tone-identity check against the golden vector) |

Codec goldens are additionally cross-checked against the pinned reference encoder at 0/162 channel
symbols (`reference/README.md`; spec §2–§5). GPS/timing verification detail is in [`docs/gps.md`](gps.md).
(The stale Phase-1 `tb_top.vhd` was retired — it tested the superseded LED-only top; review finding M2.)

**Pending / placeholder at the time of writing:**

- Calibration → increment datapath in RTL (§8 status): `cal_hz` is validated and frozen but the
  modulator increments are build-time generics.
- `src/clock/clock_control.vhd`, `tools/inspect_wspr.py`, `docs/rf.md`, `docs/verification.md`,
  `docs/lab.md` — 0-byte placeholders.
- Hardware bring-up: no iCEBreaker was attached during environment setup (`docs/environment.md` §4).
  PENDING-HARDWARE items (spec §16): board revision, ~2.8 V GPS I/O levels, 1PPS pulse width, which
  NMEA sentences are actually emitted, FTDI/UART, RF pin ratification.
- `docs/lessons.md` (plan §33 teaching walkthrough) is new; Lessons 10–11 (SDR waterfall, WSPRnet
  spotting) still lack artifacts (`docs/rf.md`, a captured WAV, `docs/verification.md`).

## 13. Sources

`docs/spec.md` §2–§13, §14, §16; plan §1.2, §1.4, §2, §4–§26, §27, §31, §32, §33, §38;
`docs/gps.md`; `docs/environment.md` §2–§4; `AGENTS.md` §2, §5; committed RTL file headers
(`src/gps/*`, `src/timing/*`, `src/nco/nco.vhd`, `src/wspr/*`, `src/top.vhd`).
