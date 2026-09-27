# WSPR-iCEBreaker — Frozen Specification

> **Phase 0 deliverable — status: FROZEN.** This file is the contract for every later phase.
> Every numeric constant the design uses appears here with a citation. Protocol constants are
> resolved against the **pinned reference implementation, WSJT-X 2.7.0** (Debian
> `2.7.0+repack-1`), whose source tree was fetched in Phase 0 and whose SHA256 matches
> `docs/environment.md` §3.3. Do not edit a frozen constant without a review of the test vectors
> (plan §29 Rule 5; `AGENTS.md` §5).

---

## 1. Scope, language and toolchain

| Constant / requirement | Value | Citation |
|---|---|---|
| HDL standard (all `src/` and `sim/`) | **VHDL-93** only — no VHDL-2008/2019, Verilog, SystemVerilog | `AGENTS.md` §2.1; plan §1.2, §30-B |
| VHDL-93 standard designation | IEEE Std 1076-1993 (a.k.a. ISO/IEC 1076:1993) | `AGENTS.md` §2.1 (the brief's "ISO/IEC 1017" is a typo; VHDL is IEEE/ISO 1076) |
| GHDL invocation | always `--std=93` on every `ghdl -a/-e/-r` | `docs/environment.md` §3.2 |
| Synthesis / P&R / bitstream | Yosys 0.69+154, nextpnr-ice40 0.11.1, IceStorm; UP5K, SG48 | `docs/environment.md` §2, §3.1; plan §3.1 |
| Reference decoder | `wsprd`, WSJT-X upstream **2.7.0** (`2.7.0+repack-1`), `/usr/bin/wsprd` | `docs/environment.md` §3.3 |
| No softcore / no MCU / no DAC / no I/Q / no Python in TX path | mandatory | `AGENTS.md` §2.5; plan §1.2, §18, §34 |

WSJT-X 2.7.0 source provenance (Phase 0): `apt-get source wsjtx` →
`/tmp/opencode/wsjtx-src/wsjtx-2.7.0+repack/`; orig tarball SHA256
`c4687b322ed36d3c526ed32e99ea48023eb76542c004a0d4658e58d8ddbf3538` — matches
`docs/environment.md` §3.3. All `file:line` citations below are to this tree.

---

## 2. WSPR Type 1 message and source encoding

| Constant | Value | Citation |
|---|---|---|
| Message form | `CALLSIGN GRID4 POWER_dBm` (Type 1) | plan §13.1; `lib/wsprd/wsprsim_utils.c:199-211` |
| Callsign field width | **28 bits** | plan §13.2; `lib/wsprd/wsprsim_utils.c:50-79` |
| Grid field width | **15 bits** | plan §13.2; `lib/wsprd/wsprsim_utils.c:42-48` |
| Power field width | **7 bits** | plan §13.2; `lib/wsprd/wsprsim_utils.c:42-48` |
| Payload | **50 bits** (28 + 15 + 7) | plan §13.2, §37; `lib/wsprd/WSPRcode.f90:94` |

**Callsign packing (28 bits).** Pad/align the callsign to exactly 6 characters: if the 3rd
character (`callsign[2]`) is a digit, copy as-is; else if the 2nd character (`callsign[1]`) is a
digit, left-shift by one and pad a leading space (`lib/wsprd/wsprsim_utils.c:53-71`). Character
codes: `'0'..'9'`→0..9, `' '`→36, `'A'..'Z'`→10..35 (`get_callsign_character_code`,
`lib/wsprd/wsprsim_utils.c:29-40`). Then
`n = 36*c0; n = 36*n + c1; n = 10*n + c2; n = 27*n + (c3-10); n = 27*n + (c4-10); n = 27*n + (c5-10)`
(`lib/wsprd/wsprsim_utils.c:72-77`).

**Grid + power packing (22 bits = 15 grid + 7 power).** Locator codes: `'0'..'9'`→0..9,
`' '`→36, `'A'..'R'`→0..17 (`get_locator_character_code`, `lib/wsprd/wsprsim_utils.c:16-27`).
For grid characters `g0 g1 g2 g3`,
`m = ((179 - 10*g0 - g2)*180 + 10*g1 + g3)*128 + power + 64`
(`pack_grid4_power`, `lib/wsprd/wsprsim_utils.c:42-48`).

**Bit assembly.** The 50 payload bits are packed MSB-first into `data[0..6]`, followed by **31
tail bits = 0** (zero-filled `data[7..10]`); `lib/wsprd/wsprsim_utils.c:255-275`:

```text
data[0]= n>>20          data[1]= n>>12          data[2]= n>>4
data[3]= ((n&0x0F)<<4) + ((m>>18)&0x0F)
data[4]= m>>10          data[5]= m>>2          data[6]= (m&0x03)<<6
data[7..10] = 0
```

**Frozen bench reference vector — `K1ABC FN42 37` (simulation/bench only; never radiate, §15).**

| Quantity | Value | Source |
|---|---|---|
| `n` (callsign) | `259047992` = `0x0F70C238` | recomputed from algorithm; matches `wsprcode` output |
| `m` (grid+power) | `2896997` = `0x2C3465` | idem |
| 50-bit payload bytes | `F7 0C 23 8B 0D 19 40` | `/usr/bin/wsprcode "K1ABC FN42 37"` (WSJT-X 2.7.0) |
| 50-bit binary | `11110111 00001100 00100011 10001011 00001101 00011001 01` | idem |

Independent packing reference (non-authoritative, for cross-check): G4JNT, *Non-normative
specification of the WSPR protocol* — <http://g4jnt.com/WSPR_Coding_Process.pdf> (plan §36 ref 8).

---

## 3. Forward error correction (FEC)

| Constant | Value | Citation |
|---|---|---|
| Constraint length | **K = 32** | plan §14; `lib/wsprd/WSPRcode.f90:94`; `lib/encode232.f90:3` |
| Code rate | **r = 1/2** | idem |
| Input bits | 50 payload + **31 tail zeros = 81** | `lib/wsprd/WSPRcode.f90:94` (`nbits=50+31`) |
| Coded bits (used) | **162** | plan §37; `lib/wsprd/WSPRcode.f90:7` |
| Code | Layland–Lushbaugh, non-systematic | `lib/wsprd/fano.c:13` (`#define LL 1`), `:46-52` |

**Generator polynomials (recorded exactly as the source defines them):**

| Name | Hex (C) | Decimal (FORTRAN `integer`) | Citation |
|---|---|---|---|
| POLY1 | **`0xf2d05351`** | `-221228207` (`npoly1`) | `lib/wsprd/fano.c:50`; `lib/conv232.f90:4`; `lib/wsprcode/wspr_old_subs.f90:69` |
| POLY2 | **`0xe4613c47`** | `-463389625` (`npoly2`) | `lib/wsprd/fano.c:51`; `lib/conv232.f90:4`; `lib/wsprcode/wspr_old_subs.f90:69` |

The two representations are identical (32-bit two's complement). Selected code branch is `LL`
(the "NASA standard" `0xbbef6bb7/0xbbef6bb5` and "MJ" `0xb840a20f/0xb840a20d` defines are
inactive), `lib/wsprd/fano.c:28-52`.

**Bit-order / packing conventions (must be reproduced exactly):**

- Input data bytes are consumed **MSB first** (`lib/wsprd/fano.c:72-74`;
  `lib/encode232.f90:12-17`).
- The encoder state is a **32-bit shift register, newest input bit in the LSB**:
  `encstate = (encstate << 1) | bit` (`lib/wsprd/fano.c:74`; `lib/encode232.f90:17`).
- For each input bit, output **POLY1 parity first, then POLY2 parity**
  (`lib/wsprd/fano.c:76-77`; `lib/encode232.f90:18-25`).
- Parity is computed over the 32-bit AND of state with the polynomial, folded with two XOR-shifts,
  then looked up in the 256-entry even-parity table:
  `_tmp=(state&POLY1); _tmp^=_tmp>>16; sym=Partab[(_tmp^(_tmp>>8))&0xff]<<1;` then the same for
  POLY2 into bit 0 (`lib/wsprd/fano.h:28-37`; FORTRAN equivalent
  `lib/encode232.f90:18-25` with `partab` defined at `lib/wsprd/tab.c:7`/`lib/conv232.f90:5+`).
- One coded bit per byte output (`lib/wsprd/fano.c:59-60`); `encode()` runs over **11 bytes**
  (= 88 bits) and the first **162** are used (`lib/wsprd/wsprsim_utils.c:298-302`).

---

## 4. Interleaving

| Item | Value | Citation |
|---|---|---|
| Definition (FORTRAN, encoder & decoder) | `inter_wspr` / `inter_mept` | `lib/inter_wspr.f90:1-45`; `lib/wsprcode/wspr_old_subs.f90:378-422` |
| Definition (C decoder) | `deinterleave` | `lib/wsprd/wsprd_utils.c:208-222` |
| Definition (C encoder) | `interleave` | `lib/wsprd/wsprsim_utils.c:145-163` |

**Algorithm (frozen):** build the 162-entry index table by the **bit-reversal of the 8-bit index**:
for `i = 0..255`, compute `n = bitreverse8(i)`; keep `n` when `n ≤ 161`, in increasing-`i` order.
This produces a permutation of `0..161`.
- Encoder (interleave): `itmp[j0(i)] = id(i)` (`lib/inter_wspr.f90:30-33`; C equivalent
  `lib/wsprd/wsprsim_utils.c:152-159`).
- Decoder (de-interleave): `itmp(i) = id(j0(i))` (`lib/inter_wspr.f90:34-37`; C equivalent
  `lib/wsprd/wsprd_utils.c:214-219`).
- No "equivalent" permutation may be substituted (plan §15). The Phase-0 generator reproduced
  `wsprcode` channel symbols **bit-for-bit (0/162 differences)** using this table.

---

## 5. Synchronisation vector and symbol combination

| Constant | Value | Citation |
|---|---|---|
| Sync vector length | **162 bits** | `lib/wsprd/WSPRcode.f90:7,15-26` |
| Source of truth (FORTRAN) | `sync(162)` (`data` statement) | `lib/wsprd/WSPRcode.f90:17-26` |
| Same vector (FORTRAN, TX) | `npr3(162)` | `lib/genwspr.f90:9-19` |
| Same vector (C, RX) | `pr3[162]` | `lib/wsprd/wsprd.c:55-63`; `lib/wsprd/wsprsim_utils.c:169-178` |
| Combination rule | **`tone_symbol = 2*data_bit + sync_bit`** → {0,1,2,3} | `lib/wsprd/WSPRcode.f90:118`; `lib/genwspr.f90:24-26`; `lib/wsprd/wsprsim_utils.c:306-308` |

The frozen 162-bit synchronisation vector (`lib/wsprd/WSPRcode.f90:17-26`):

```text
1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0,
0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1,
0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1,
1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1,
0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0,
0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1,
0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1,
0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0,
0, 0
```

The four tones are `tone_symbol ∈ {0,1,2,3}`; `sync_bit` is the frozen vector, `data_bit` the
interleaved FEC output (§4), one bit per symbol.

---

## 6. Modulation and timing constants

| Constant | Frozen value | Exact expression | Citation |
|---|---|---|---|
| Tone spacing | **1.46484375 Hz** | `12000/8192` Hz | plan §9, §37; `lib/wsprd/wsprd.c:209` (`df=375.0/256.0`); `lib/wsprd/wsprsimf.f90:47` (`baud=12000.0/8192.0`) |
| Symbol duration | **8192/12000 s** = `0.68266…` s | `8192/12000` | plan §10, §37; `lib/wsprd/wsprd.c:209,276` (`dt=1/375`, 256 samples/symbol) |
| Number of symbols | **162** | — | plan §10, §37; `lib/wsprd/WSPRcode.f90:7` |
| TX duration | **110.592 s** (exact) | `162 × 8192/12000` | plan §10, §37 |
| Slot length | **120 s**, even UTC minute | — | plan §10, §37; `widgets/mainwindow.cpp:8142` (`m_TRperiod=120.0`) |
| Tone offsets from carrier `f0` | `-1.5, -0.5, +0.5, +1.5` × spacing, for tones 0..3 | `(tone-1.5)*baud` | `lib/wsprd/wsprsimf.f90:67-73`; `lib/wsprd/wsprd.c:234-250` |
| Modulation | continuous-phase 4-FSK, single accumulated phase, 1-bit GPIO | — | plan §16, §17, §18 |

Audio AFSK convention (bench/verification): nominal audio centre **1500 Hz** on a USB dial
frequency; `wsprd` downconverts around 1500 Hz (`lib/wsprd/wsprd.c:118-127`); WSJT-X default WSPR
audio Tx frequency is 1500 Hz (`widgets/mainwindow.cpp:1487`).

---

## 7. TX start offset within the even minute — RESOLVED

> **FROZEN VALUE: the first WSPR symbol starts at +1.000 s after 00:00.000 of the even UTC
> minute.** The signal therefore occupies +1.000 s … +111.592 s of the 120 s slot. This is the
> decoder-facing and scheduler-facing value; the "2 s" wording in a source comment and in some
> secondary references (e.g. ARRL; plan §0.1) is **not** used.

### 7.1 Scheduler side (WSJT-X GUI, 2.7.0)

- `widgets/mainwindow.cpp:5023-5029`: `nsec = ms/1000` (ms since UTC midnight);
  `nseq = fmod(nsec, m_TRperiod)`, `m_TRperiod = 120.0` for WSPR
  (`widgets/mainwindow.cpp:8142`). Because UTC midnight is an even minute, `nseq == 0` occurs at
  the top of each even UTC minute.
- `widgets/mainwindow.cpp:5038-5047`: for `m_mode=="WSPR"`, Tx/Rx is decided when
  `nseq==0 and m_ntr==0`; a Tx sequence sets `m_bTxTime=true`.
- `Modulator/Modulator.cpp:72`: `unsigned delay_ms=1000;` — the WSPR/other-mode default is
  **1000 ms**; the overrides at `:73-76` apply only to FT8/FST4/FT4/Q65, **not** to WSPR.
- `Modulator/Modulator.cpp:87-100` and `:174-184`: the modulator emits `m_silentFrames` of
  silence first, "so that audio will start at the nominal time `delay_ms` into the Tx sequence".
- Therefore the WSPR audio waveform (first symbol) starts **1.000 s into the Tx sequence =
  1.000 s into the even UTC minute**.

### 7.2 Decoder side (`wsprd`, 2.7.0)

- `lib/wsprd/wsprd.c:1455-1461`: the reported offset is
  `dt_print = shift1*dt - 1.0` (with `dt=1/375`, `lib/wsprd/wsprd.c:758`). Hence DT = 0 means the
  signal started **1.0 s into the file**.
- `lib/wsprd/wsprd.c:1136-1145` contains the comment "nominal start time, which is 2 seconds into
  the file" and "The program prints DT = shift-2 s". This comment is **internally inconsistent
  with the code immediately below it** (`:1455-1461`) and with the scheduler.

### 7.3 Empirical adjudication against `wsprd` 2.7.0 (Phase 0)

A synthetic Type-1 `K1ABC FN42 37` signal was encoded with the exact WSJT-X 2.7.0 algorithms
(§2–§5) and verified bit-for-bit against the installed reference encoder
(`wsprcode "K1ABC FN42 37"`: 0/162 channel-symbol differences), then placed at a known offset in
a 120 s / 12 kHz / 16-bit mono WAV and decoded with `/usr/bin/wsprd` 2.7.0:

| Signal start | `wsprd` reported DT | Command |
|---|---|---|
| **1.000 s** | **-0.0 / 0.1** (i.e. ≈0) | `wsprd -v -f 10.140210 260927_1202.wav` |
| 2.000 s | 1.0 / 1.2 | `wsprd -v -f 10.140210 260927_1204.wav` |

Both decoded `K1ABC FN42 37` at 10.141710 MHz. The decoder's physical nominal start is therefore
**1.0 s**, confirming `dt_print = shift - 1.0` and the scheduler's `delay_ms=1000`.

**Justification for freezing 1 s:** the decoder is the acceptance criterion (plan §30-H), and its
executable code and empirical behaviour both give 1.0 s; the scheduler independently gives 1.0 s.
The 2 s figure survives only in a stale source comment.

---

## 8. Clock, calibration and NCO

| Constant | Frozen value | Notes | Citation |
|---|---|---|---|
| Nominal FPGA clock | **`NOMINAL_CLOCK_HZ = 12000000`** (12 MHz) | onboard oscillator, shared with FT2232H | plan §3.1, §6; `AGENTS.md` §2.7 |
| NCO phase-accumulator width | **40 bits** | `frequency_resolution = calibrated_clock / 2^40` | plan §8 |
| NCO frequency resolution @12 MHz | `12e6/2^40` ≈ **1.0914e-5 Hz** | ≪ tone spacing 1.46484375 Hz | derived from plan §8 |
| Calibration window | **`CALIBRATION_SECONDS = 8`** default, **configurable** | may be 8 or 16 intervals; average | plan §7 |
| Calibration cadence | **before every TX**, frozen for the duration of that TX | no dynamic retune during TX (v1) | plan §1.4, §24 |
| 1PPS measurement basis | count FPGA clocks between consecutive 1PPS rising edges | measures the real clock against GPS time | plan §6 |
| Measurement expected value | ≈ **12,000,000** cycles/s at nominal | — | plan §6 |

The measured clock is never assumed to be exactly 12 MHz; the NCO increment is computed from the
freshly calibrated value and held constant during a transmission (`AGENTS.md` §2.7; plan §1.4,
§7, §24). Timing must use a fractional symbol-time accumulator, not a rounded "683 ms" wait
(plan §10).

---

## 9. RF frequency default (DEFAULT-CONFIGURABLE — not frozen protocol)

| Constant | Value | Status | Citation |
|---|---|---|---|
| `DEFAULT_RF_FREQUENCY_HZ` | **`10140200`** (30 m WSPR segment centre) | DEFAULT-CONFIGURABLE; per-band value selected at build/config time | WSPRnet *WSPR Frequencies* (`http://www.wsprnet.org/drupal/sites/wsprnet.org/files/wspr-qrg.pdf`): 30 m dial 10 138.7 kHz, band 10 140.1–10 140.3 kHz ⇒ centre **10 140.2 kHz** |
| WSJT-X 30 m WSPR dial | `10138700` Hz | band data | `models/FrequencyList.cpp:176` |
| WSJT-X default WSPR audio Tx | `1500` Hz | ⇒ 10 138 700 + 1500 = 10 140 200 Hz | `widgets/mainwindow.cpp:1487` |

**Discrepancy note (frozen honestly):** the Phase-0 brief suggested `10_140_210`. No authoritative
source located gives `10 140 210`; the WSPRnet band table and WSJT-X band data + default 1500 Hz
audio give `10 140 200` as the 30 m WSPR centre. The 30 m WSPR segment is 200 Hz wide
(10 140 100–10 140 300 Hz), so either displayed value is within the segment. Because this constant
is explicitly **configurable and not protocol-critical**, the spec freezes `10140200` with the
citations above; the top-level default may be overridden per configuration (plan §9, §35).
No protocol constant depends on it.

Other standard WSPR dial frequencies (for §35 V3 multi-band work) — WSPRnet *WSPR Frequencies*:
160 m 1 836.6, 80 m 3 568.6, 60 m 5 287.2, 40 m 7 038.6, 30 m 10 138.7, 20 m 14 095.6,
17 m 18 104.6, 15 m 21 094.6, 12 m 24 924.6, 10 m 28 124.6 kHz (all USB dial). Not frozen here.

---

## 10. PmodGPS (rev. A) — interface constants

| Constant | Value | Citation |
|---|---|---|
| Module | GlobalTop FGPMMOPA6H / MediaTek MT3329 | Digilent *PmodGPS Reference Manual*, rev. April 12 2016, DOC# 502-237, p.1 |
| J1 pinout | 1=3DF, 2=RX, 3=TX, 4=1PPS, 5=GND, 6=VCC(3.3 V) | Digilent manual, Table 1 (p.3) |
| J2 pinout (not used initially) | 1=~RST, 2=RTCM | Digilent manual, Table 1 (p.3) |
| UART | **9600 baud, 8 data bits, no parity, 1 stop bit (8N1)**; default 9.6 kBd, configurable 4.8–115.2 kBd | Digilent manual, p.2 |
| Default NMEA sentences | **GGA, GSA, GSV, RMC, VTG** (talker ID `GP`) | Digilent manual, Tables 2–6 (pp.4–6) |
| 3DF behaviour | stays low with a constant 2D/3D fix; toggles once per second with no fix | Digilent manual, p.2, Fig. 2 |
| 1PPS behaviour | one pulse per second, synchronised to GPS time; pulse width shown in Fig. 1 (≈100 ms per plan §3.2) | Digilent manual, p.2 + Fig. 1; plan §3.2 |
| Supply | 2.7–5.25 V, recommended 3.3 V | Digilent manual, p.3 |
| Module I/O logic level | ≈ **2.8 V TTL** (FGPMMOPA6H/MT3329) | plan §3.2 (GlobalTop PA6H datasheet); **PENDING-HARDWARE** (§16) |
| Time-reference rule | **1PPS is the primary time reference**; NMEA gives *which* second, PPS gives *where it begins*; never use NMEA arrival time as the second reference | plan §11; `AGENTS.md` §2.7 |
| Minimum required parse | valid fix, UTC hour, UTC minute, UTC second | plan §11 |
| Connection (TX use) | Pmod GPS TX → FPGA UART RX; 1PPS → FPGA PPS input; 3DF optional; GND; 3.3 V | plan §3.3 |

Official manual URL: <https://digilent.com/reference/pmod/pmod/gps/ref_manual>
(Phase 0 fetched PDF: `https://digilent.com/reference/_media/reference/pmod/pmodgps/pmodgps_rm.pdf`).

---

## 11. iCEBreaker pin source of truth and pin plan

**Source of truth (do not invent pins; plan §3.1, `AGENTS.md` §2.4):**

- Official example PCF: `icebreaker/icebreaker.pcf` in
  **`https://github.com/icebreaker-fpga/icebreaker-examples`**.
- Commit fetched: **`cb9e674cbf0facb84684b02567eb55df3018726b`** (2021-06-01);
  blob `d3097d5bfdf59d7229604ae287df4fb9677b492b`.
- Permalink:
  <https://github.com/icebreaker-fpga/icebreaker-examples/blob/cb9e674cbf0facb84684b02567eb55df3018726b/icebreaker/icebreaker.pcf>
- Note: the URL in the brief (`https://github.com/icebreaker-fpga/icebreaker`) now contains only a
  README that says the project moved to Codeberg
  (<https://codeberg.org/icebreaker-fpga/icebreaker>, hardware files only); it no longer contains
  `examples/`. The PCF above is the official example PCF from the official examples repository.

Relevant pins (numbers are iCE40UP5K SG48 PCF pin numbers, exactly as in the official PCF):

| Function | Official PCF signal | PCF pin | Notes |
|---|---|---|---|
| 12 MHz clock | `CLK` | **35** | plan §3.1, §6 |
| On-board red LED | `LEDR_N` | **11** | active-low; the two on-board user LEDs (a.k.a. LED1/LED2) — plan §32 |
| On-board green LED | `LEDG_N` | **37** | active-low (output-only PLL pin) |
| RGB LED (optional diagnostics) | `LED_RED_N` / `LED_GRN_N` / `LED_BLU_N` | 39 / 40 / 41 | plan §32 |
| FTDI UART RX / TX (diagnostics) | `RX` / `TX` | **6** / **9** | plan §32 |
| Push button | `BTN_N` | 10 | optional |
| PMOD 1A | `P1A1..P1A4`, `P1A7..P1A10` | 4, 2, 47, 45, 3, 48, 46, 44 | PmodGPS host (below) |
| PMOD 1B | `P1B1..P1B4`, `P1B7..P1B10` | 43, 38, 34, 31, 42, 36, 32, 28 | free (RF candidate) |
| PMOD 2 / snap-off | `P2_1..P2_4`, `P2_7..P2_10` | 27, 25, 21, 19, 26, 23, 20, 18 | free (note LED1..LED5 also use some of these) |

**PmodGPS ↔ PMOD 1A mapping** (Pmod J1 pins 1–6 → PMOD1A): 3DF → `P1A1` (FPGA **4**),
RX → `P1A2` (**2**), TX → `P1A3` (**47**, → FPGA UART RX), 1PPS → `P1A4` (**45**, → FPGA PPS),
GND → GND, VCC → 3.3 V. For the transmitter only TX (pin 3) and 1PPS (pin 4) are required, plus
GND/3.3 V; 3DF is optional (`plan §3.3`).

**RF GPIO output — PROPOSED (to be frozen in `constraints/icebreaker.pcf` by the hardware agent,
Phase 1):** `P1B10` = FPGA pin **28** on PMOD 1B (single bit, `rf_out : out std_logic`, plan §18).
Any otherwise-unused PMOD 1B/2 signal pin is acceptable; this choice is deliberately left outside
the frozen protocol and must come from the official PCF, not be invented.

> This spec does **not** write `constraints/icebreaker.pcf`; it records the authoritative source
> and the pin numbers only.

---

## 12. Failure behaviour (design requirements)

From plan §31 (binding, not optional error handling):

| Condition | Required behaviour |
|---|---|
| No GPS | **NO TX** — no transmission without a valid time reference |
| GPS loses fix | Do not start a new transmission until a valid reference is recovered |
| PPS disappears | Invalidate calibration |
| Corrupt NMEA | Do not change the existing valid time |
| Measured frequency out of bounds | Enter error state, do not transmit |
| Invalid PLL/clock | Do not transmit |
| Reset during TX | RF output must shut off immediately |

---

## 13. Diagnostics (design requirements)

From plan §32; observable without a CPU:

- GPS valid; PPS detected; measured clock; calibrated clock; UTC; scheduler state; TX active;
  current symbol; NCO increment.
- Preferably via the iCEBreaker UART (FTDI, pins 6/9), LEDs (`LEDR_N`=11, `LEDG_N`=37), and
  internal signals accessible in simulation. No CPU may be added for diagnostics.
- Diagnostic registers must be named constants/documented, no hidden magic numbers (plan §6).

---

## 14. Ratified repository layout (plan §27, as built in Phase 0)

```text
wspr-icebreaker/
├── README.md, LICENSE, Makefile, AGENTS.md          # AGENTS.md is an added governance file
├── constraints/icebreaker.pcf                       # (placeholder at Phase 0)
├── src/
│   ├── top.vhd
│   ├── clock/clock_control.vhd
│   ├── gps/{gps_uart,gps_parser,gps_time,pps_measure}.vhd
│   ├── timing/{clock_calibration,wspr_scheduler}.vhd
│   ├── nco/nco.vhd
│   └── wspr/{wspr_message,wspr_fec,wspr_interleave,wspr_sync,wspr_symbols,wspr_modulator}.vhd
├── sim/{tb_pps_measure,tb_clock_calibration,tb_nco,tb_wspr_message,
│        tb_wspr_fec,tb_wspr_interleave,tb_wspr_symbols,tb_wspr_top}.vhd
├── reference/{wspr_reference.py, test_vectors/k1abc_fn42_37.txt, README.md}
├── tools/{calculate_nco.py, inspect_wspr.py}
├── docs/{architecture,protocol,gps,rf,verification,lab,environment,spec}.md
└── doc/   # pre-existing planning briefs (orchestrator plan, agent briefs); not edited
```

This matches plan §27; the only additions are `AGENTS.md`, `docs/environment.md`, `docs/spec.md`
and the pre-existing `doc/` tree. The structure may be simplified only if a split hurts
readability (plan §27). Rule: one agent per file at a time (`AGENTS.md` §5).

---

## 15. Bench-only warning and legal requirement (binding)

`K1ABC FN42 37` is a **conventional documentation/bench vector only**. It must **never** be
radiated over the air. Over-the-air transmission requires a valid amateur-radio licence
appropriate to the operator and jurisdiction, the operator's **own assigned callsign**, and
compliance with the local band plan and power limits. The WSPR `power` field must reflect the
**actual radiated RF power**, not the GPIO logic level (plan §0.1, §25; `AGENTS.md` §2.6).

---

## 16. PENDING-HARDWARE

The following physical items could not be verified in Phase 0 (no board attached; plan §3.2,
`docs/environment.md` §4). They are documentary-only until a board and PmodGPS are in hand:

1. **Board revision.** Confirm the actual iCEBreaker revision in hand (V1.0b/V1.1a/…) against the
   schematic; the pin map above is from the official example PCF and is revision-independent for
   the pins listed, but must be confirmed.
2. **Electrical levels.** Measure the PmodGPS NMEA/1PPS high level (documented ≈2.8 V TTL) against
   the iCE40 LVCMOS33 input thresholds on the chosen pins; decide whether level shifting is
   required (plan §3.2). Not assumed.
3. **1PPS pulse width.** Confirm the pulse width on the actual unit from the manual's Fig. 1
   (≈100 ms, plan §3.2); the edge detector must trigger on the rising edge, not assume a narrow
   pulse.
4. **NMEA sentence presence.** Experimentally confirm which sentences appear (documented default:
   GGA, GSA, GSV, RMC, VTG) and which is reliably present; the parser must use one confirmed
   sentence type (plan §11).
5. **FTDI/UART and programming.** Exercise `iceprog -t` and the FTDI UART on hardware
   (`docs/environment.md` §4).
6. **RF output pin ratification.** Freeze the RF GPIO pin in `constraints/icebreaker.pcf` in
   Phase 1 (see §11, PROPOSED).

---

## 17. Citations

| Ref | Source | Used for |
|---|---|---|
| WSJT-X 2.7.0 source (pinned) | `apt-get source wsjtx` → `wsjtx-2.7.0+repack`; orig SHA256 `c4687b32…bf3538` (`docs/environment.md` §3.3) | all `file:line` protocol claims |
| `lib/wsprd/fano.c`, `lib/wsprd/fano.h` | K=32 r=1/2 encoder/decoder | polynomials, bit order |
| `lib/conv232.f90`, `lib/encode232.f90`, `lib/wsprcode/wspr_old_subs.f90` | FORTRAN FEC / interleaver | polynomials, interleave |
| `lib/inter_wspr.f90`, `lib/genwspr.f90` | FORTRAN interleaver / TX symbol gen | interleave, sync, combination |
| `lib/wsprd/WSPRcode.f90` | reference encoder program | sync vector, combination rule |
| `lib/wsprd/wsprsim_utils.c`, `lib/wsprd/wsprd_utils.c`, `lib/wsprd/wsprd.c` | source encoding, interleave, decoder timing | packing, DT convention |
| `lib/wsprd/wsprsimf.f90` | WSPR simulator | tone offsets, baud |
| `widgets/mainwindow.cpp`, `Modulator/Modulator.cpp` | GUI scheduler / modulator | TX start offset |
| `models/FrequencyList.cpp`, `widgets/mainwindow.cpp` | band data | 30 m dial frequency |
| `lib/wsprd/wsprsim_utils.c:199-211` | Type-1 recognition | message form |
| Orchestrator plan | `doc/wspr_icebreaker_orchestrator_plan.md` §0.1, §3, §4, §6–§18, §27, §31, §32, §36, §37 | requirement constants |
| Project constraints | `AGENTS.md` §2, §5 | VHDL-93, pin policy, workflow |
| Environment | `docs/environment.md` §2, §3, §4 | toolchain, WSJT-X pin, hardware status |
| iCEBreaker example PCF | `https://github.com/icebreaker-fpga/icebreaker-examples`, commit `cb9e674c…`, `icebreaker/icebreaker.pcf` | pins |
| iCEBreaker docs | `https://docs.icebreaker-fpga.org/hardware/icebreaker/` | board features, LEDs |
| Digilent PmodGPS RM | `https://digilent.com/reference/pmod/pmod/gps/ref_manual` (DOC# 502-237, rev. 2016-04-12) | J1 pinout, 9600 8N1, NMEA, 1PPS, 3DF |
| WSPRnet WSPR Frequencies | `http://www.wsprnet.org/drupal/sites/wsprnet.org/files/wspr-qrg.pdf` | 30 m WSPR segment → `DEFAULT_RF_FREQUENCY_HZ` |
| G4JNT | `http://g4jnt.com/WSPR_Coding_Process.pdf` | non-normative packing cross-check |
| K1JT/W1BW, QST Nov 2010 | `https://wsjt.sourceforge.io/WSPR_QST_Nov_2010.pdf` | protocol background, band table |

**Change control:** any change to a constant in §2–§7 triggers a re-review of the test vectors
(plan §29 Rule 5). No protocol approximation is permitted without explicit justification
(plan §29 Rule 6).

---

*Phase 0 — Frozen Documentation & Requirements. Created 2026-09-27.*
