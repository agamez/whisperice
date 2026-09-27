# GPS / timing chain — block documentation

Blocks: `src/gps/gps_uart.vhd`, `src/gps/gps_parser.vhd`, `src/gps/gps_time.vhd`,
`src/gps/pps_measure.vhd`, `src/timing/clock_calibration.vhd`,
`src/timing/wspr_scheduler.vhd`. Testbenches: `sim/tb_gps_uart.vhd`,
`sim/tb_gps_parser.vhd`, `sim/tb_gps_time.vhd`, `sim/tb_pps_measure.vhd`,
`sim/tb_clock_calibration.vhd`, `sim/tb_wspr_scheduler.vhd`.

All RTL is VHDL-93 (every `ghdl` invocation uses `--std=93`; testbenches scale
time via generics/parameters only, plan §21). Frozen parameters come from
`docs/spec.md` (§7 TX offset, §8 clock/calibration, §10 GPS) — see also the
plan (§2, §3, §6–§8, §11, §31, §32).

## Signal chain

```text
PmodGPS UART TX ──► gps_uart ──► gps_parser ──► gps_time ──► wspr_scheduler
PmodGPS 1PPS   ──► pps_measure ──┘              │              │
                                                │              ├─► tx_enable ──► wspr_modulator.tx_start
 clock_calibration ◄────────────────────────────┘──────────────┘ (symbol_tick ◄─ modulator)
```

## Block contracts

### gps_uart (`CLOCK_HZ` generic, default 12 000 000; `BAUD_RATE` 9600)
- `data(7:0)`, `data_valid` (1-cycle pulse per received byte), `framing_error`
  (1-cycle pulse; the byte is discarded).
- 2-FF synchronizer on RX; start-bit centre confirmation; centre-of-bit
  sampling; LSB first. Bit period = CLOCK_HZ/BAUD truncated (1250 cycles at
  12 MHz; UART tolerates the truncation error).
- No overrun/FIFO path: the parser consumes every byte immediately and NMEA at
  9600 baud leaves ample time; a dropped byte aborts one sentence (plan §31
  safe). A deliberate overrun flag would require a consumption ack — removed
  as dead logic (adversarial review finding).

### gps_parser
- Accepts `$--RMC` sentences only (`SENTENCE_TYPE` constant). Commits iff:
  checksum matches (XOR of bytes between `$` and `*`), address ends with RMC,
  field 2 carried exactly 6 digits forming valid hh:mm:ss, and field 3 status
  is `A`.
- Outputs: `time_strobe` (commit pulse), `hour/minute/second`, `fix_valid`
  (sticky; last committed state), `sentence_error` (rejection pulse),
  `fix_warning` (pulse when a checksum-valid RMC carries status `V` — the fix
  is lost, plan §31).
- Rejected sentences never change the committed outputs (plan §31).
- NOTE: whether this PmodGPS unit emits RMC is PENDING-HARDWARE (spec §16).

### gps_time
- 1PPS is the primary time reference: `pps_tick` advances one second. NMEA
  (`time_strobe`) only says WHICH second it is; loads apply immediately and
  the UART arrival time is never used for timing (plan §11).
- `utc_valid` rises on the first load; drops on `fix_warning` (status V) or
  reset. Rollovers: s 59→0 bumps minute, minute 59→0 bumps hour, hour 23→0.
- `minute_even` = valid AND minute even — high for the WHOLE even minute; the
  scheduler fires at `second = 1` inside it (spec §7: +1.000 s offset).

### pps_measure (Agent B1)
- `pps_in` → 2-FF sync → rising-edge detect (single-cycle `pps_tick`; the
  PmodGPS 1PPS pulse is ~100 ms wide — edge-detected, never level-sampled).
- `measured_cycles_per_second` latched each PPS (25-bit counter, reset-to-1 so
  the latched value is exactly the interval); `measurement_valid` clears after
  `TIMEOUT_CYCLES` (default 24 M = 2 s) without an edge. The counter measures
  the FPGA clock against the GPS second, not the other way around (plan §6).

### clock_calibration (Agent B1)
- Averages `CALIBRATION_SECONDS` (generic, default 8, plan §7) valid
  measurements with round-half-up → `calibrated_clock_hz`; sets
  `calibration_frozen` and holds until the next `start` rising edge.
- Bounds via generics (`CAL_MIN_HZ`/`CAL_MAX_HZ`, default ±1000 ppm):
  out-of-bounds → `calibration_error='1'`, `calibration_valid='0'` (plan §31:
  do not transmit). PPS loss mid-window invalidates.
- Handshake: `start` (rising edge) begins a window; `cal_valid`/`cal_error`
  are LEVELS that persist after the window — consumers must act on EDGES.

### wspr_scheduler
- FSM: `WAIT_GPS → CALIBRATE → READY → WAIT_SLOT → TX → TX_DONE → CALIBRATE → …`
  (state numbers on `state_o`: 0,1,2,3,4,5 — plan §8).
- Fires TX when `minute_even='1'` AND `second=1` (spec §7: +1.000 s into the
  even UTC minute) AND `slot_mask(minute/2)='1'` (runtime port, plan §12;
  default all-ones from the top level).
- `tx_enable` is a 1-cycle pulse into `wspr_modulator.tx_start`;
  `symbol_tick` (from the modulator) advances `symbol_index` 0..161; the
  integration muxes the codec's tone vector (wspr_symbols, Agent C) with
  `symbol_index` to feed the modulator's 2-bit tone input.
- Calibration handshake is EDGE-based: `READY` only on a `cal_valid` rising
  edge (fresh window); a `cal_error` rising edge re-pulses `cal_start`.
  `TX_DONE` returns to `CALIBRATE` so every transmission is preceded by a
  fresh calibration (plan §7). Stale levels can never substitute for a window.
- Failure behavior (plan §31): no UTC → WAIT_GPS (no TX); `utc_valid` drops
  (fix lost or status-V seen) → WAIT_GPS; reset mid-TX → RF off immediately
  (modulator gates `rf_out`).

## Verification status

- All six testbenches pass with `ghdl --std=93` (and `-fexplicit -Wbinding`).
- Testbenches are non-vacuous: negative controls demonstrated (mutated
  expected count/time → failure, rc=1).
- PENDING-HARDWARE (spec §16): board revision, electrical levels (~2.8 V GPS
  I/O), actual NMEA sentence set emitted by the unit, 1PPS pulse width.
