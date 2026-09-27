# Plan: Autonomous WSPR Transmitter on iCEBreaker + PmodGPS

> **Review note (this revision):** The original plan's hardware and protocol figures were checked
> against primary/official sources (see **§36 References**). Almost everything was correct. A few
> points needed correction, clarification, or an explicit flag because the source documentation is
> genuinely inconsistent. These are marked **⚠ VERIFIED / CORRECTED** inline and summarized in
> **§0.1**.

---

## 0. Objective

Implement a **real, autonomous, protocol-compliant WSPR beacon** using:

- an **iCEBreaker** board
- **Lattice iCE40UP5K** FPGA
- the board's onboard **12 MHz** oscillator
- a **Digilent PmodGPS rev. A**, based on the GlobalTop FGPMMOPA6H module (MediaTek MT3329 chipset)
- a single 1-bit GPIO as the digital RF output
- an external RF filter and, optionally, an external matching/amplification stage

All HDL must be **VHDL-93**.

The goal is not merely "a transmission that sort of works": the code must be **simple, readable,
verifiable, and pedagogical**, so the project can be used as teaching material in an FPGA/SDR
course.

The final deliverable must produce a valid WSPR transmission that real stations can decode and
report to WSPRnet.

### 0.1 Summary of verification findings

| Item | Original plan | Verification result |
|---|---|---|
| iCE40UP5K, 12 MHz oscillator | Correct | ✅ Confirmed against iCEBreaker docs |
| PmodGPS rev. A: FGPMMOPA6H / MT3329 | Correct | ✅ Confirmed against Digilent's official reference manual |
| PmodGPS J1 pinout (3DF, RX, TX, 1PPS, GND, 3.3V) | Correct | ✅ Confirmed pin-for-pin against the official reference manual (Table 1) |
| GPS module internal signal logic ≈ 2.8 V | Correct | ✅ Confirmed (GlobalTop PA6H datasheet: 1PPS/NMEA I/O at 2.8 V TTL) |
| WSPR: 50 bits, K=32, r=1/2, 162 symbols | Correct | ✅ Confirmed against K1JT/ARRL and Wikipedia |
| Tone spacing 12000/8192 = 1.46484375 Hz | Correct | ✅ Confirmed |
| Symbol duration 8192/12000 s | Correct | ✅ Confirmed |
| TX duration 110.592 s | Correct (exact value; most public sources round to "110.6 s") | ✅ Confirmed, plan already uses the more precise exact fraction |
| Slot length 120 s (even UTC minute) | Correct | ✅ Confirmed |
| **Exact TX start offset within the even minute** | Not specified numerically (only "even UTC minute") | ⚠ **Flagged, not an error.** Public sources disagree: current Wikipedia/K1JT wording says transmissions start **1 second** into the even minute; the ARRL page and several other secondary sources say **2 seconds**. This must be pinned down empirically against the exact WSJT-X/`wsprd` build used for decoding tests (see §37) rather than assumed from any single secondary source. |
| No hard-coded amateur-radio licensing/legal requirement | Missing | ⚠ **Added.** Actually transmitting RF requires a valid amateur radio license appropriate to the operator and jurisdiction, use of the operator's own assigned callsign, and compliance with the local band plan. `K1ABC FN42 37` is a conventional example message used throughout WSPR documentation — it must **not** be radiated over the air; it is only a bit-exact reference vector for simulation/bench testing. |
| FEC polynomials not spelled out numerically | Only "polynomial A / polynomial B" | ⚠ **Added.** The reference generator polynomials are documented in the WSJT-X source and in G4JNT's non-normative write-up (see §36); the plan now requires the encoder agent to pull these directly from one pinned, cited source rather than from memory. |

Nothing in the verification invalidates the architecture, the phase breakdown, or the multi-agent
orchestration plan below; the corrections are refinements to reduce ambiguity before RTL is
written.

---

## 1. Design Principles

### 1.1 Absolute priority: protocol correctness

Do not implement a "WSPR-like" variant.

The final transmission must be compatible with standard WSPR decoders, especially WSJT-X.

It must respect:

- message format
- source compression
- forward error correction (FEC)
- interleaving
- synchronization vector
- sync/data bit combination
- 4-FSK
- continuous phase
- tone spacing
- symbol duration
- total transmission duration
- slot timing

The encoder must be verified against an independent reference implementation.

### 1.2 Absolute priority: VHDL-93

Do not use:

- VHDL-2008
- SystemVerilog
- Verilog
- a softcore CPU
- MicroBlaze
- RISC-V
- any embedded processor
- firmware required for transmission

The transmitter must be autonomous FPGA logic.

Auxiliary tools in Python/C/etc. are allowed for:

- generating test vectors
- verifying results
- comparing against WSJT-X
- automating simulations

But the synthesized design itself must be VHDL-93.

### 1.3 Pedagogical priority

Avoid premature optimization.

Prefer:

```text
one simple block
        ↓
one register
        ↓
one counter
        ↓
one clear state machine
```

over:

```text
a highly optimized block
+
auto-generated RTL that is hard to read
+
FPGA-specific tricks
```

The implementation must be explainable to SDR/FPGA students.

Every block must have an obvious single responsibility.

### 1.4 Do not assume the 12 MHz clock is stable

The iCEBreaker's onboard oscillator is a practical reference, but it can carry error and drift.

The system must periodically measure it using the GPS **1PPS** signal.

Calibration must happen **before every transmission**, and the calibrated value must be frozen for
the duration of that transmission.

Do not assume that:

```text
"12 MHz"
```

is actually exactly 12 MHz.

---

## 2. Global Architecture

```text
                         PmodGPS
                    ┌────────────────┐
                    │                │
                    │ UART TX ───────┼──────────► FPGA UART RX
                    │                │
                    │ 1PPS ──────────┼──────────► FPGA PPS input
                    │                │
                    └────────────────┘


                    ┌──────────────────────────┐
                    │        iCEBreaker        │
                    │                          │
12 MHz oscillator ─►│ clock                    │
                    │   │                      │
                    │   ├──► PPS measurement   │
                    │   │                      │
                    │   ├──► GPS time          │
                    │   │                      │
                    │   ├──► calibration       │
                    │   │                      │
                    │   ├──► WSPR scheduler    │
                    │   │                      │
                    │   ├──► WSPR encoder      │
                    │   │                      │
                    │   ├──► symbol timing     │
                    │   │                      │
                    │   └──► NCO / 4-FSK       │
                    │              │           │
                    └──────────────┼───────────┘
                                   │
                              RF GPIO (1 bit)
                                   │
                                   ▼
                              RF low-pass /
                              band-pass filter
                                   │
                                   ▼
                              optional PA
                                   │
                                   ▼
                                antenna
```

---

## 3. Reference Hardware

### 3.1 iCEBreaker

Use the standard iCEBreaker with:

- iCE40UP5K (QFN48/SG48 package), 5,280 logic cells, 128 Kbit dual-port BRAM, 1 Mbit single-port
  RAM, PLL, two SPI and two I2C hard IPs, two internal oscillators (10 kHz and 48 MHz), 8 DSP
  blocks
- a 12 MHz crystal oscillator shared between the FT2232H USB bridge and the FPGA
- the fully open-source toolchain: **Yosys** (synthesis), **nextpnr-ice40** (place & route),
  **Project IceStorm** (bitstream generation/`iceprog` programming)

✅ Confirmed against the official iCEBreaker hardware repository and documentation (§36, refs 1–2).

Use the official iCEBreaker example `.pcf` as the pin reference. **Do not invent pin
assignments** — always verify against the board's official PCF/schematic.

### 3.2 PmodGPS

The specified PmodGPS is:

- Digilent PmodGPS rev. A
- GlobalTop FGPMMOPA6H module
- MediaTek MT3329 GPS chipset

It provides:

- UART (default 9,600 baud, 8N1)
- 1PPS
- 3DF (fix status) signal
- 3.3 V power

✅ Confirmed against Digilent's official PmodGPS reference manual (§36, ref 3): the manual
communicates over UART and exposes a 1PPS output synchronized to GPS time, exactly as stated.

**Important — electrical levels:** the GPS module's own I/O (NMEA UART and 1PPS) is generated at
approximately **2.8 V** logic levels by the FGPMMOPA6H/MT3329 silicon (confirmed against the
GlobalTop PA6H datasheet, §36 ref 4), even though the Pmod itself is powered at 3.3 V. Verify
electrically what the selected iCE40 input pin actually requires (nominal LVCMOS33 input
thresholds vs. a ~2.8 V high level) before wiring 1PPS/UART directly to the FPGA. In practice this
usually works without extra level shifting on iCE40 LVCMOS33 inputs, but it must be checked, not
assumed — do not skip this check.

Also note: the 1PPS pulse width from this module is on the order of ~100 ms (see the reference
manual's timing diagram), not a single clock edge — the synchronizer/edge-detector design in
Phase 2 must be written with this in mind (detect the rising edge, don't assume a narrow pulse).

### 3.3 PmodGPS connection

The PmodGPS rev. A reference manual specifies, for connector J1:

```text
J1
pin 1 = 3DF
pin 2 = RX
pin 3 = TX
pin 4 = 1PPS
pin 5 = GND
pin 6 = 3.3 V (VCC)
```

✅ Confirmed pin-for-pin against Digilent's official reference manual, Table 1 (§36 ref 3).

For the transmitter, we initially need only:

```text
PmodGPS TX   -> FPGA UART RX
PmodGPS 1PPS -> FPGA PPS input
GND          -> GND
3.3 V        -> 3.3 V
```

Do not connect the FPGA's TX line to the GPS's RX pin unless you intend to send configuration
commands to the module later (e.g. changing baud rate or update rate via `$PMTK...` sentences).

---

## 4. Phase 0 — Frozen Documentation & Requirements

Before writing any RTL:

1. Verify the exact iCEBreaker hardware revision in hand.
2. Verify the official schematic/PCF.
3. Verify the PmodGPS revision (rev. A) against its manual.
4. Verify electrical levels (§3.2).
5. Locate the official WSPR/WSJT-X protocol documentation.
6. Locate an independent reference implementation of the encoder for cross-checking.
7. **Resolve the exact TX start offset** (1 s vs. 2 s into the even UTC minute — see §0.1) against
   the specific WSJT-X/`wsprd` version that will be used for decode testing.
8. Define the final repository layout.
9. Write a short, frozen specification.

Deliverable:

```text
docs/spec.md
```

It must contain every numeric constant the design will use, each with its citation (see §37 for
the initial frozen values and §36 for sources).

---

## 5. Phase 1 — iCEBreaker Infrastructure + VHDL-93

Create a minimal project first:

```text
src/
  top.vhd
constraints/
  icebreaker.pcf
Makefile
README.md
```

It must:

- synthesize with Yosys;
- place & route with nextpnr-ice40;
- generate a bitstream with Project IceStorm;
- program the iCEBreaker (`iceprog`);
- demonstrate that the 12 MHz clock is working.

Add a first simple test:

```text
12 MHz -> divider -> LED
```

Do not move forward until you have a reproducible build flow.

---

## 6. Phase 2 — 1PPS Input

Create an independent block:

```text
pps_sync.vhd
```

Responsibilities:

1. Synchronize 1PPS into the FPGA clock domain.
2. Detect the rising edge.
3. Generate a single-cycle internal pulse.
4. Avoid metastability using a two-flip-flop synchronizer.
5. Measure the number of clock cycles between consecutive PPS pulses.

Architecture:

```text
External PPS
    │
    ▼
FF synchronizer
    │
    ▼
edge detector
    │
    ▼
pps_tick
```

#### Frequency measurement

Count clock cycles between consecutive PPS pulses.

With a nominal 12 MHz clock:

```text
expected ≈ 12,000,000 cycles/s
```

The measured value will be:

```text
measured_cycles_per_second
```

Keep a diagnostic register.

Do not use hidden magic numbers. Example:

```vhdl
constant NOMINAL_CLOCK_HZ : integer := 12000000;
```

The design must clearly document that the counter measures the FPGA's real clock frequency
against the GPS second, not the other way around.

---

## 7. Phase 3 — Clock Calibration

Do not trust a single one-second measurement if it can be avoided.

Implement a short calibration window before transmitting.

Initial proposal:

```text
GPS fix
  ↓
wait for PPS
  ↓
measure 8 or 16 PPS intervals
  ↓
average
  ↓
obtain effective FPGA clock frequency
  ↓
compute NCO increment
  ↓
freeze calibration
  ↓
transmit
```

The exact averaging window (in seconds) must be configurable. Example:

```vhdl
constant CALIBRATION_SECONDS : integer := 8;
```

The goal is to remove counter quantization error and reduce measurement noise.

### Important requirement

Calibration must be performed **before every WSPR transmission**.

Do not assume a calibration done an hour earlier is still valid.

The design must allow for crystal drift caused by:

- temperature
- supply voltage
- time
- environment

---

## 8. Phase 4 — NCO

Create:

```text
nco.vhd
```

Responsibility: generate a continuous-phase digital carrier.

Architecture:

```text
phase_accumulator
        │
        ▼
phase + phase_increment
        │
        ▼
MSB
        │
        ▼
RF GPIO
```

Do not use a sine lookup table initially. The output will be a 1-bit square wave. Filtering
harmonics is the responsibility of external hardware.

#### Accumulator width

Use a 40-bit accumulator initially.

Document the reasoning:

```text
frequency_resolution = calibrated_clock / 2^40
```

This is far finer than the spacing between WSPR tones (1.46484375 Hz), leaving comfortable margin
for the calibrated 12 MHz reference.

---

## 9. Phase 5 — RF Frequency and WSPR Tone Calculation

The transmitter must be configurable for a specific RF frequency. Do not hard-code a single
frequency across every block.

Separate:

```text
RF center frequency
+
WSPR tone number
```

For WSPR (✅ confirmed, §36 refs 5–7):

```text
tone spacing = 12000 / 8192
             = 1.46484375 Hz
```

The four tones are:

```text
f0
f0 + 1.46484375 Hz
f0 + 2 * 1.46484375 Hz
f0 + 3 * 1.46484375 Hz
```

For HF, `f0` must represent the true carrier frequency actually radiated. It must be configurable
via top-level constants. Conceptual example:

```vhdl
constant RF_FREQUENCY_HZ : integer := ...;
```

Avoid floating-point arithmetic in RTL. NCO increment calculation must use clean integer /
fixed-point arithmetic.

A small Python script may generate exact constants for the chosen configuration.

---

## 10. Phase 6 — Exact WSPR Timing

WSPR uses:

- 162 symbols
- symbol rate = 12000/8192 Hz
- symbol duration = 8192/12000 s ≈ 0.68266667 s
- total duration = 110.592 s (exact)
- 120 s slot

Do not implement the symbol timer as:

```text
wait 683 ms
```

because that introduces cumulative rounding error.

Use a fractional accumulator (a "symbol-time accumulator") analogous to the NCO's phase
accumulator, so timing stays exact over all 162 symbols.

The specification must clearly distinguish:

```text
RF frequency
symbol rate
absolute GPS time
```

---

## 11. Phase 7 — UTC Synchronization

The GPS provides UTC via NMEA sentences and the exact second boundary via 1PPS.

Implement:

```text
gps_uart.vhd
gps_time.vhd
```

You do not need to implement the entire NMEA standard — parse only the fields strictly required.

Preferably use a single, stable NMEA sentence type — for example RMC or GGA — whichever is
confirmed to be reliably present on this PmodGPS unit experimentally (the module supports GGA,
GSA, GSV, RMC and VTG by default; see §36 ref 3).

The parser must extract at minimum:

```text
valid fix
UTC hour
UTC minute
UTC second
```

Do not store or process unnecessary GPS data.

### Design rule

1PPS is the primary time reference.

NMEA tells you:

```text
which UTC second this is
```

PPS tells you:

```text
exactly where that second physically begins
```

Do not use the UART arrival time of the NMEA sentence as a time reference — NMEA sentences arrive
with variable latency after the PPS edge they describe.

---

## 12. Phase 8 — WSPR Scheduler

Create:

```text
wspr_scheduler.vhd
```

Recommended states:

```text
WAIT_GPS
CALIBRATE
READY
WAIT_SLOT
TX
TX_DONE
```

Flow:

```text
WAIT_GPS
   ↓
GPS valid
   ↓
CALIBRATE
   ↓
calibration valid
   ↓
READY
   ↓
even UTC minute
   ↓
slot start (exact offset frozen in docs/protocol.md — see §0.1 / §37)
   ↓
TX
   ↓
110.592 s
   ↓
TX_DONE
   ↓
wait for next slot
```

Whether to transmit on a given slot must be explicit and configurable.

For initial testing:

```text
transmit on every available slot
```

A slot divider can be added later to avoid needlessly occupying the band (WSPR etiquette
typically recommends transmitting on a fraction of available slots, not continuously).

---

## 13. Phase 9 — WSPR Encoder

This is one of the most important blocks.

Create separate, readable blocks:

```text
wspr_message.vhd
wspr_fec.vhd
wspr_interleave.vhd
wspr_sync.vhd
wspr_symbols.vhd
```

Do not create a single hundreds-of-lines `wspr.vhd`.

### 13.1 Initial format

Implement **WSPR Type 1** first:

```text
CALLSIGN GRID4 POWER_dBm
```

Reference example (a conventional documentation example — do not transmit it over the air; see
§0.1):

```text
K1ABC FN42 37
```

Type 1 is the first goal. Do not implement Type 2/3 until Type 1 is fully verified.

### 13.2 Source encoding

The message compresses to:

```text
50 bits
```

Distribution for Type 1 (✅ confirmed, §36 refs 5–8):

```text
callsign = 28 bits
grid     = 15 bits
power    = 7 bits
```

Implement every step visibly. Do not hide the encoding inside enormous expressions. The character
set and packing rules (callsign padding/alignment, the 37-symbol alphabet for grid/power, etc.)
are non-trivial and must be implemented against a cited reference (§36 ref 8), not from memory.

---

## 14. Phase 10 — FEC

Implement the WSPR convolutional code:

```text
constraint length K = 32
rate = 1/2
```

With:

```text
50 input bits
+
31 tail bits
=
81 bits
```

Then:

```text
81 × 2 = 162 coded bits
```

✅ Confirmed against K1JT/ARRL and Wikipedia (§36 refs 5–7).

The implementation must clearly show:

```text
input bit
   ↓
shift register K=32
   ↓
polynomial A
polynomial B
   ↓
2 output bits
```

**The two generator polynomials must be taken verbatim from a single cited, pinned source** (the
WSJT-X `wsprd`/`wsprcode` source tree, or G4JNT's non-normative write-up — §36 refs 9–10) and
documented in `docs/protocol.md` alongside that citation. Do not reconstruct them from memory or
from an unverified blog post.

---

## 15. Phase 11 — Interleaving

Implement the WSPR interleaver as an independent block.

Do not replace it with an "equivalent" permutation.

The final 162-bit sequence must be compared against a known reference.

Create a fixed test vector:

```text
K1ABC FN42 37
```

and store the expected result.

---

## 16. Phase 12 — Sync Vector

Implement the 162-bit synchronization vector exactly, then combine:

```text
tone_symbol =
    2 * data_bit
    + sync_bit
```

Result:

```text
0, 1, 2, or 3
```

Each symbol selects one of the four tones. This relationship must be explicit in the code, since
it is pedagogically important. The sync vector itself must be taken from a cited source and
verified bit-for-bit against the encoder test vector.

---

## 17. Phase 13 — Continuous-Phase 4-FSK

Do not implement four independent oscillators.

There must be **one single accumulated phase**.

When the symbol changes:

```text
phase_increment =
    carrier_increment
    +
    tone_increment * symbol
```

The accumulator's phase continues seamlessly from the previous symbol.

This guarantees the **continuous-phase 4-FSK** property.

Architecture:

```text
WSPR symbol
     │
     ▼
tone selector
     │
     ▼
tone frequency offset
     │
     ▼
NCO phase increment
     │
     ▼
phase accumulator
     │
     ▼
RF GPIO
```

---

## 18. Phase 14 — GPIO Output

The final output must be exactly one bit:

```vhdl
rf_out : out std_logic;
```

No DAC. No I/Q generation. No PWM as a modulation method.

The GPIO is the digital carrier. Removing harmonics is the job of external hardware.

---

## 19. Phase 15 — RF Filtering

The RTL must not attempt to solve RF filtering. The project must document:

```text
FPGA GPIO
    ↓
series resistor / matching
    ↓
band-pass filter appropriate to the chosen band
    ↓
optional PA
    ↓
antenna
```

For the first test:

```text
GPIO
 ↓
attenuator
 ↓
local SDR receiver
```

Do not connect an antenna directly without first checking harmonic filtering and the output
conditions. The design must be testable at extremely low power first.

---

## 20. Phase 16 — Offline Verification

This phase is mandatory before transmitting over RF.

Build a Python reference model. It must:

1. take callsign/grid/power as input;
2. generate the 50 bits;
3. apply FEC;
4. apply interleaving;
5. add sync;
6. generate the 162 symbols;
7. generate frequencies/tones.

The RTL must produce the exact same sequence.

### Minimum test

Use:

```text
K1ABC FN42 37
```

as the reference vector (bench/simulation only — see §0.1).

Compare:

```text
source bits
coded bits
interleaved bits
162 symbols
```

The test must fail on a single-bit difference.

---

## 21. Phase 17 — RTL Simulation

Use a simulator compatible with the open-source flow, e.g. **GHDL**.

Testbenches must be VHDL-93.

Create independent tests:

```text
tb_nco.vhd
tb_pps_measure.vhd
tb_gps_time.vhd
tb_wspr_fec.vhd
tb_wspr_interleave.vhd
tb_wspr_symbols.vhd
tb_wspr_scheduler.vhd
tb_wspr_top.vhd
```

Do not simulate 120 seconds at 12 MHz from the start. Create configurable simulation time scales
to speed up tests. Functional logic must remain identical; only test parameters may be scaled
down.

---

## 22. Phase 18 — Local RF Test

Before using an antenna:

```text
iCEBreaker
    ↓
GPIO
    ↓
filter/attenuator
    ↓
SDR
```

Check:

1. center frequency;
2. tone spacing;
3. stability;
4. symbol duration;
5. phase continuity;
6. absence of unexpected glitches;
7. total duration of 110.592 s;
8. silence outside the transmission window.

Capture a waterfall.

---

## 23. Phase 19 — Local Decoding

Generate a transmission and receive it with an SDR.

Process it with a reference WSPR/WSJT-X implementation.

Goal:

```text
TX:
K1ABC FN42 37

RX:
K1ABC FN42 37
```

Do not consider the project complete until a real decoder recognizes the transmission. Ideally
also test at very low signal levels.

---

## 24. Phase 20 — Real GPS-Based Calibration

With GPS acquired:

```text
PPS
 ↓
clock measurement
 ↓
average
 ↓
calculated_clock_hz
 ↓
NCO increment
```

Calibration runs before every TX.

During TX:

```text
calculated_clock_hz = frozen
```

Do not dynamically change the increment during a transmission in the first version.

Pedagogical rationale:

- avoids frequency jumps;
- keeps behavior deterministic;
- allows later study of drift effects.

A later, experimental version may add tracking during TX.

---

## 25. Phase 21 — Real Transmission

Only after passing all previous tests.

Sequence:

```text
1. GPS fix
2. valid UTC
3. measure clock
4. compute calibration
5. prepare message
6. wait for WSPR slot
7. enable RF
8. transmit 162 symbols
9. disable RF
10. wait for next slot
11. repeat calibration
```

The power value included in the WSPR message must correspond to the **actual radiated RF power**,
not the logical power available at the GPIO.

**Before transmitting on any amateur band, confirm you hold an appropriate amateur radio license
for your jurisdiction, use your own assigned callsign (never `K1ABC` or another example
callsign), and follow the local band plan and power limits.**

---

## 26. Phase 22 — Reception on WSPRnet

A remote station receiving the signal should generate a spot with:

```text
callsign
grid
SNR
frequency
DT
distance
receiver
```

The final experimental objective:

```text
iCEBreaker
    ↓
PmodGPS
    ↓
WSPR
    ↓
antenna
    ↓
HF propagation
    ↓
remote station
    ↓
WSJT-X
    ↓
WSPRnet
```

A real spot appearing is the final functional success criterion.

---

## 27. Recommended Repository Structure

```text
wspr-icebreaker/
│
├── README.md
├── LICENSE
├── Makefile
│
├── constraints/
│   └── icebreaker.pcf
│
├── src/
│   ├── top.vhd
│   │
│   ├── clock/
│   │   └── clock_control.vhd
│   │
│   ├── gps/
│   │   ├── gps_uart.vhd
│   │   ├── gps_parser.vhd
│   │   ├── gps_time.vhd
│   │   └── pps_measure.vhd
│   │
│   ├── timing/
│   │   ├── clock_calibration.vhd
│   │   └── wspr_scheduler.vhd
│   │
│   ├── nco/
│   │   └── nco.vhd
│   │
│   └── wspr/
│       ├── wspr_message.vhd
│       ├── wspr_fec.vhd
│       ├── wspr_interleave.vhd
│       ├── wspr_sync.vhd
│       ├── wspr_symbols.vhd
│       └── wspr_modulator.vhd
│
├── sim/
│   ├── tb_pps_measure.vhd
│   ├── tb_clock_calibration.vhd
│   ├── tb_nco.vhd
│   ├── tb_wspr_message.vhd
│   ├── tb_wspr_fec.vhd
│   ├── tb_wspr_interleave.vhd
│   ├── tb_wspr_symbols.vhd
│   └── tb_wspr_top.vhd
│
├── reference/
│   ├── wspr_reference.py
│   ├── test_vectors/
│   │   └── k1abc_fn42_37.txt
│   └── README.md
│
├── tools/
│   ├── calculate_nco.py
│   └── inspect_wspr.py
│
└── docs/
    ├── architecture.md
    ├── protocol.md
    ├── gps.md
    ├── rf.md
    ├── verification.md
    └── lab.md
```

The structure may be simplified if, during implementation, a given split is shown to hurt
readability rather than help it.

---

## 28. Work Breakdown Across Subagents

The orchestrator must use specialized subagents.

### Agent A — Hardware / documentation

Responsibility:

- verify iCEBreaker;
- verify iCE40UP5K;
- verify the clock;
- verify the PCF;
- verify PmodGPS;
- verify electrical levels;
- document connections.

Does not write RTL except small test examples.

Deliverables:

```text
docs/hardware.md
constraints/icebreaker.pcf
```

---

### Agent B — GPS / timing

Responsibility:

- UART;
- NMEA parser;
- PPS synchronizer;
- frequency measurement;
- calibration;
- UTC;
- scheduler.

Must write unit tests.

---

### Agent C — WSPR codec

Exclusive responsibility:

- Type 1;
- source encoding;
- FEC;
- interleaving;
- sync vector;
- 162 symbols.

Must provide reference vectors.

Does not touch RF or GPS.

---

### Agent D — NCO / modulator

Responsibility:

- NCO;
- increment calculation;
- 4-FSK;
- continuous phase;
- symbol timing;
- GPIO output.

Must demonstrate via simulation that the frequencies are correct.

---

### Agent E — Verification

Responsibility:

- independent Python model;
- RTL/reference comparison;
- GHDL;
- test vectors;
- full-sequence validation.

Must try to break the design, not merely confirm it works.

---

### Agent F — Integration

Responsibility:

- integrating all blocks;
- Makefile;
- constraints;
- bitstream;
- hardware testing.

Does not modify internal algorithms except to resolve interfaces.

---

### Agent G — Pedagogical review

Responsibility: review the entire project as if it were course material.

Must catch:

- overly complex code;
- poor naming;
- magic numbers;
- blocks with too many responsibilities;
- insufficient comments;
- unnecessary abstractions;
- hidden dependencies;
- VHDL that is not VHDL-93-compatible.

This agent may propose simplifications even if the code already works.

---

## 29. Orchestrator Rules

**Rule 1.** Do not allow multiple agents to modify the same file simultaneously.

**Rule 2.** Every block must have:

```text
RTL
+
testbench
+
documentation
```

**Rule 3.** An agent cannot declare a block finished just because it synthesizes. A functional
test must exist.

**Rule 4.** The integrator must not silently "fix" another agent's bugs. It must return the
problem to the responsible agent.

**Rule 5.** Any change to a WSPR constant must trigger a review of the test vectors.

**Rule 6.** Do not accept protocol approximations without explicit justification.

---

## 30. Acceptance Criteria

**A — Build.**

```text
make clean
make
```

must produce a bitstream with no errors.

**B — VHDL.** All RTL must be VHDL-93.

**C — GPS.** With a GPS fix:

- PPS detected;
- valid UTC;
- frequency measured;
- calibration updated.

**D — NCO.** Simulation and SDR measurement must demonstrate:

```text
f_out ≈ f_configured
```

within the error expected from NCO resolution.

**E — WSPR codec.** For the test vector:

```text
K1ABC FN42 37
```

the 162 symbols must match the reference exactly.

**F — Modulation.** Must demonstrate:

```text
4 tones
1.46484375 Hz spacing
continuous phase
162 symbols
110.592 s
```

**G — Synchronization.** The transmission must fall in the correct UTC slot, at the exact offset
frozen in `docs/protocol.md` (§0.1/§37).

**H — Decoding.** WSJT-X must decode the locally captured signal.

**I — Real RF.** A remote station must be able to decode it and generate a spot.

---

## 31. Failure Behavior

The design must define what happens when:

**No GPS.**

```text
NO TX
```

Do not transmit a supposedly precise WSPR beacon without a valid time reference.

**GPS loses fix.** Do not start a new transmission until a valid reference is recovered.

**PPS disappears.** Invalidate calibration.

**Corrupt NMEA.** Do not change the existing valid time.

**Measured frequency out of bounds.** Enter an error state and do not transmit.

**Invalid PLL/clock.** Do not transmit.

**Reset during TX.** RF must shut off immediately.

---

## 32. Diagnostics and Observability

Even though the final beacon is autonomous, there must be a simple way to observe:

```text
GPS valid
PPS detected
measured clock
calibrated clock
UTC
scheduler state
TX active
current symbol
NCO increment
```

Preferably via:

- the iCEBreaker's UART;
- LEDs for basic states;
- internal signals accessible in simulation.

Do not add a CPU purely for diagnostics.

---

## 33. Pedagogical Design

The documentation must include a teaching walkthrough:

```text
Lesson 1  — GPIO and clocking
Lesson 2  — counter and 1PPS
Lesson 3  — frequency measurement
Lesson 4  — NCO
Lesson 5  — FSK
Lesson 6  — FEC
Lesson 7  — interleaving
Lesson 8  — WSPR
Lesson 9  — GPS + synchronization
Lesson 10 — SDR and waterfall
Lesson 11 — remote reception / WSPRnet
```

Each lesson should be able to isolate one block of the system.

---

## 34. What NOT to Do

Do not:

- use a softcore;
- use an external microcontroller;
- depend on Python to transmit;
- generate WSPR symbols in real time from a PC;
- use a DAC;
- use I/Q;
- implement an approximation of WSPR;
- ignore crystal error;
- use UART sentence arrival time as the second reference;
- abruptly change frequency during a transmission in the first version;
- hide the codec inside generated code;
- optimize before having a readable version;
- sacrifice clarity to save a few LUTs;
- transmit RF using an example callsign (e.g. `K1ABC`) instead of your own licensed callsign.

---

## 35. Later Evolution

Once the educational, stable version is complete:

### V2 — Tracking during TX

Continuously measure PPS and study how much the oscillator drifts during the 110.592 s
transmission. Compare:

```text
calibration only before TX
```

against:

```text
continuous tracking
```

without compromising phase continuity.

### V3 — Multiple bands

Allow selecting among the standard WSPR HF bands:

```text
160 m
80 m
40 m
30 m
20 m
17 m
15 m
12 m
10 m
```

while keeping exactly the same codec.

### V4 — Band hopping

Add band-scheduling following WSPR conventions.

### V5 — Configurable power

Integration with an external PA and automatic update of the `power` field.

---

## 36. Normative References

These are the sources this plan's numeric values were checked against. Anything not covered here
must be verified against the exact WSJT-X source version used for decode testing before being
frozen in `docs/protocol.md`.

1. iCEBreaker hardware documentation and repository (board specs, 12 MHz oscillator, iCE40UP5K) —
   https://github.com/icebreaker-fpga/icebreaker and https://docs.icebreaker-fpga.org/hardware/icebreaker
2. iCEBreaker board specification summary —
   https://boards.fpgadeveloper.com/boards/iCEBreaker
3. Digilent PmodGPS (rev. A) Reference Manual — official pinout, UART parameters, 1PPS/3DF
   behavior —
   https://www.mouser.com/datasheet/2/690/pmodgps_rm-846365.pdf (mirrored at
   https://digilent.com/reference/pmod/pmod/gps/ref_manual)
4. GlobalTop FGPMMOPA6H / MediaTek MT3329 module notes (2.8 V I/O logic levels, 1PPS after 3-D fix)
   — https://scivision.dev/globaltop-fgpmmopa6h-gps-10hz-1pps
5. WSPR protocol summary (Wikipedia; includes the current "1 second into the even minute" wording)
   — https://en.wikipedia.org/wiki/WSPR_(amateur_radio_software)
6. ARRL, "WSPR" summary page (includes the "2 seconds into the even minute" wording — see §0.1
   discrepancy note) — https://www.arrl.org/wspr
7. Taylor, K1JT & Walker, W1BW, "WSPRing Around the World," QST, Nov. 2010 (original protocol
   description, FEC/timing rationale) — https://wsjt.sourceforge.io/WSPR_QST_Nov_2010.pdf
8. G4JNT, "Non-normative specification of the WSPR protocol" (step-by-step source-encoding,
   callsign/grid/power packing) — http://g4jnt.com/WSPR_Coding_Process.pdf
9. WSJT-X source tree (`wsprd`/`wsprcode`), the authoritative implementation for FEC polynomials
   and the sync vector — https://sourceforge.net/p/wsjt/wsjtx/ci/master/tree/lib/wsprd/
10. qrp-labs, empirical WSPR timing-accuracy measurement notes (useful for validating slot-timing
    tests against a real GPS-disciplined transmitter) — https://qrp-labs.com/ultimate3/u3info/dt.html
11. Open-source FPGA toolchain: Yosys — https://github.com/YosysHQ/yosys ;
    nextpnr — https://github.com/YosysHQ/nextpnr ;
    Project IceStorm — https://clifford.at/icestorm/
12. GHDL (open-source VHDL simulator) — https://ghdl.github.io/ghdl/

Do not treat blogs or third-party implementations as protocol authority when official
documentation or reference source code is available. Where two credible secondary sources
disagree (as with the 1 s vs. 2 s slot-start offset), resolve the disagreement empirically against
the actual decoder build used for testing, and record the resolution with its citation.

---

## 37. Frozen WSPR Protocol Constants (initial reference)

The project must freeze protocol figures from the chosen reference documentation and must not mix
values from different implementations.

Initial reference values (✅ verified against §36, refs 5–9):

```text
payload              50 bits
constraint length    K = 32
coded bits           162
modulation           continuous-phase 4-FSK
tone spacing         12000/8192 Hz
                     = 1.46484375 Hz
symbol duration      8192/12000 s
                     = 0.682666... s
TX duration          110.592 s
slot                 120 s
TX start offset      even UTC minute; exact sub-second offset (1 s vs 2 s — see §0.1)
                     MUST be confirmed against the specific WSJT-X/wsprd build used for
                     testing before being frozen here
```

The exact TX start timing must be checked against the reference WSJT-X version used for testing
and frozen in `docs/protocol.md`, citing that WSJT-X version explicitly.

---

## 38. Expected Final Result

At the end, there must be a board that:

```text
             ┌─────────────────┐
             │   iCEBreaker    │
             │                 │
 GPS ───────►│ UTC + PPS       │
             │                 │
             │ clock calibr.   │
             │                 │
             │ WSPR encoder    │
             │                 │
             │ 4-FSK NCO       │
             │                 │
             └────────┬────────┘
                      │
                    1 bit
                      │
                    BPF
                      │
                     PA
                      │
                   ANTENNA
```

can stay powered on indefinitely, obtain GPS time, measure its own clock's real frequency,
recalibrate before every transmission, and generate a fully valid WSPR transmission.

The ultimate success criterion is not that the waterfall "looks like WSPR." It is:

```text
iCEBreaker
   ↓
real transmission
   ↓
remote WSPR receiver
   ↓
correct decode
   ↓
spot on WSPRnet
```

And the code must stay simple enough that a student can open `wspr_fec.vhd`, `nco.vhd`, or
`pps_measure.vhd` and understand what is happening.
