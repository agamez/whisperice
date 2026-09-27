# RF output — band selection, filtering and the transmit chain

> Planning annex for the transmit side of the beacon (plan §19: "the GPIO is the digital carrier;
> removing harmonics is the job of external hardware"). Every number below is either cited to a
> pinned source, produced by the provenance tool [`tools/calculate_nco.py`](../tools/calculate_nco.py),
> or explicitly marked **PENDING-HARDWARE** (spec §16). Nothing here is a protocol constant —
> protocol constants live in [`docs/spec.md`](spec.md) and [`docs/protocol.md`](protocol.md) and are
> unaffected by this document.

## 1. What the pin outputs

`rf_out` (pin 28, P1B10 — `constraints/icebreaker.pcf`, spec §11) is a **1-bit, sample-rate
digital output**: the modulator's phase-accumulator MSB, driven as 3.3 V CMOS logic and updated
once per clock (`f_clk = 12 MHz`, spec §8). Electrically it is a zero-order-hold (ZOH) 1-bit DAC:
a staircase that changes at most every 83.3 ns.

Consequences for the RF chain:

- **Directly representable content is limited to `f_clk/2 = 6 MHz`** (Nyquist; `nco.vhd` header,
  `architecture.md` §11). WSPR carriers below 6 MHz appear (nearly) as the square wave's own
  fundamental.
- **The analog spectrum consists of lines at `m·f_clk ± f_alias`**, where `f_alias` is the
  carrier's content folded into `0…6 MHz`, each line weighted by the ZOH envelope
  `w(f) = |sinc(f / f_clk)|` (first-order model; measure at bring-up). There is also a strong line
  at exactly 12 MHz (the sampling operation) and broadband 1-bit quantisation noise.
- **Tone order rule (important).** A spectral line at frequency `F` carries the 4-FSK symbols
  - **in the correct order** iff `F ≡ f_carrier (mod f_clk)`, and
  - **inverted** (tone 0 highest) iff `F ≡ −f_carrier (mod f_clk)`.

  Worked example (30 m): the wanted lines sit at 10 140 200 Hz (correct order) and are mirrored at
  `12 MHz − 10 140 200 = 1 859 800 Hz` — the *folded* line is **tone-inverted and unusable for
  WSPR**, even though it is ~15 dB *stronger* (table below). A band-pass filter for image operation
  must select the `F ≡ +f_carrier` line and reject the fold. Never "use the fold".

  This rule is verified numerically by
  [`tools/check_tone_order.py`](../tools/check_tone_order.py) on the real 40-bit increments
  (ZOH-staircase spectrum): RF line order CORRECT, fold line INVERTED, fold/RF amplitude
  ratio measured +14.6 dB (sinc model +14.75 dB).

## 2. Band table

Dial frequencies are the **pinned WSJT-X 2.7.0 defaults** (`models/FrequencyList.cpp`, lines 58/65/
68/105/140/176/217 in the `2.7.0+repack` source). The RF centre convention is `RF = dial + 1500 Hz`
(USB audio offset; `widgets/mainwindow.cpp:9832` computes `rfreq = dial + 1500`, and the default
WSPR audio frequency is 1500 Hz, `widgets/mainwindow.cpp:1487`). This reproduces the frozen spec §9
default exactly: `10 138 700 + 1 500 = 10 140 200 Hz = DEFAULT_RF_FREQUENCY_HZ`.

Carrier increments are from `tools/calculate_nco.py --frequency <RF>` at 12 MHz (40-bit
accumulator); `w` is the first-order ZOH amplitude weight of the usable line.

| Band | Dial (WSJT-X 2.7.0) | RF centre (dial + 1500) | Line used | w (estimate) | Carrier increment | Achieved error |
|---|---|---|---|---|---|---|
| 2200 m | 136 000 Hz | 137 500 Hz | direct fundamental | −0.00 dB | 12 598 570 735 (`0x02EEEEEEEF`) | +0.7 µHz |
| 630 m | 474 200 Hz | 475 700 Hz | direct fundamental | −0.02 dB | 43 586 473 444 (`0x0A25F4CDE4`) | −4.6 µHz |
| 160 m | 1 836 600 Hz | 1 838 100 Hz | direct fundamental | −0.34 dB | 168 417 693 585 (`0x27367A0F91`) | +4.5 µHz |
| 80 m | 3 568 600 Hz | 3 570 100 Hz | direct fundamental | −1.30 dB | 327 113 871 860 (`0x4C298191F4`) | −2.8 µHz |
| 40 m | 7 038 600 Hz | 7 040 100 Hz | image `12 − 4.9599` | −5.64 dB | 645 055 984 225 (`0x9630553261`) | −5.3 µHz |
| 30 m | 10 138 700 Hz | 10 140 200 Hz | image `12 − 1.8598` | −15.08 dB | 929 105 650 665 (`0xD8530323E9`) | +5.3 µHz |
| 20 m | 14 095 600 Hz | 14 097 100 Hz | image (`f ≡ +f_c` mod 12) | −16.99 dB | 1 291 660 447 327 mod 2⁴⁰ = 192 148 819 551 | +2.7 µHz |

Notes:

- All achieved errors are ≤ 5.3 µHz — five orders of magnitude below the 1.46484375 Hz tone
  spacing (`tools/calculate_nco.py`; docs/spec.md §6). The calibrated (not nominal) clock shifts
  all tones together by the same ppm error; WSPR tolerates this (decoder search window).
- For carriers above `f_clk` (20 m) the raw increment exceeds 2⁴⁰; the RTL constants are its
  residue mod 2⁴⁰ (the accumulator arithmetic is mod-2⁴⁰ anyway). The tool prints the raw value.
- The 40 m image is only ~5.6 dB down and the 12 MHz clock line is 5 MHz away — 40 m is the
  easiest *image-operated* band. 30 m (the spec default) costs ~15 dB and needs the filter to
  reject a clock line just 1.86 MHz above the carrier.

## 3. Recommended first configuration

1. **80 m (3 570 100 Hz) first, into a 50 Ω dummy load.** Direct fundamental (−1.3 dB), strong
   WSPR population, simplest filter, and the folded image (8.4299 MHz) is far away. 160 m is
   equivalent but needs a bigger antenna when you finally radiate.
2. **Then 40 m** to exercise image operation with the most forgiving numbers (−5.6 dB image,
   clock line 5 MHz away).
3. **Then 30 m** (spec §9 default) — the WSPR flagship band — accepting the −15 dB image and the
   tight 1.86 MHz rejection of the 12 MHz clock line.

For all bands the receiver side of the world uses the WSJT-X/WSPRnet dial + 1500 Hz convention of
§2, so the beacon's RF centre must sit at the listed RF centre *as measured*, i.e. after
calibration the tone grid must be within decoder tolerance of it (plan §26; spec §7).

## 4. Transmit chain (bench)

```text
rf_out (pin 28) ──[series R]──[optional buffer/driver]──[BPF per band]──[attenuator]──► 50 Ω dummy load
                                                                      └─(later)──► antenna (licensed OTA only)
```

- **The GPIO is not a radio.** Never connect an antenna directly to the pin; the 1-bit output is
  rich in harmonics and clock feedthrough (plan §18/§19: external hardware removes them).
- **The pin cannot drive 50 Ω.** A 3.3 V swing into 50 Ω would demand ~66 mA (Ohm's law) — far
  beyond a logic pin. Keep the DC load impedance high (series resistance, or a logic buffer /
  small driver stage as the first active element). The exact data-sheet current limit and the
  series-R value are **PENDING-HARDWARE** — to be ratified from the Lattice iCE40UP5K data sheet
  during bring-up (spec §16); no value is frozen here.
- **Order of operations for bring-up**: dummy load → scope/SMA measurement of the actual spectrum
  → filter design *from the measurement* → and only then, with a licence and the operator's own
  callsign configured (plan §25), an attenuated antenna test.
- **Duty cycle**: the shipped `SLOT_MASK_C` transmits in every even minute (~50 % airtime). WSPR
  etiquette and most band plans expect far less — reduce the slot mask (`top.vhd`, plan §12/§35)
  before any over-the-air operation.

## 5. Filter requirements checklist

The band-pass filter (2–4 pole LC is plenty for WSPR's 6 Hz bandwidth) must, per band:

| Rejection target | 160/80 m (direct) | 40 m (image) | 30 m (image) |
|---|---|---|---|
| 12 MHz clock line | far (≥ 6 MHz away) | 5.0 MHz away | **1.86 MHz away — hardest item** |
| Folded alias line (tone-inverted!) | n/a (it is the fundamental's image, far away) | 4.9599 MHz | 1.8598 MHz, far below passband |
| Odd harmonics of the carrier | 3f, 5f, … (e.g. 80 m: 10.71, 17.85 MHz) | 21.12, 35.2 MHz | 30.42, 50.7 MHz |
| 1-bit quantisation noise | broadband; the BPF sets the transmitted noise floor | same | same |

Additional constraints:

- Stop-band attenuation at the image distances above should exceed the level differences in the
  §2 table (e.g. for 30 m, reject the 1.86 MHz fold by ≫ 15 dB relative to the wanted line, since
  the fold starts ~15 dB *stronger*).
- Insertion loss trades directly against the §2 `w` figures — 30 m has ~15 dB less signal to
  spend than 80 m.
- **PENDING-HARDWARE**: actual pin spectrum measurement (scope + SA or an SDR) ratifies all filter
  decisions and the RF pin assignment (spec §16). Design the filter *after* that measurement.

## 6. Level estimates (first-order, to be measured)

For a 0–3.3 V square wave, the fundamental amplitude is `4·(3.3/2)/π ≈ 2.10 V_pk` (1.48 V RMS):

- **Direct drive (no series R, impossible for the pin itself)** into 50 Ω would be ~+16 dBm —
  this is the ceiling a proper driver stage could deliver.
- **Through a 330 Ω series resistor into 50 Ω** (example only, not a frozen value): the divider
  gives ≈ 0.20 V RMS → ≈ 0.8 mW ≈ **−1 dBm**. WSPR decodes to −31 dB SNR, and milliwatt-level
  spots on 160/80 m are routine with a reasonable antenna — but this assumes the full fundamental
  reaches the load, before filter insertion loss and the §2 `w` factors (30 m: subtract ~15 dB).
- Buffer/driver stage selection, attenuator values and the final ERP are **PENDING-HARDWARE**.

## 7. Legal and safety (binding, not optional)

- **Never radiate an example/bench callsign.** "K1ABC FN42 37" and the like are simulation vectors
  only (plan §25; `top.vhd` header). Over-the-air operation requires a licence, the operator's own
  callsign/grid/power compiled into `top.vhd`, and operation within the operator's privileges.
- **Bench testing uses a dummy load** — a 50 Ω resistor rated for the drive power. Radiation is a
  licensing event, not an engineering step.
- Respect WSPR band segments and power limits applicable to the operator's licence class; the
  beacon transmits automatically and unattended (plan §35 etiquette).

## 8. PENDING-HARDWARE items (spec §16)

- RF pin ratification (P1B10 / pin 28) against the actual iCEBreaker board revision.
- Measured pin spectrum (fundamental, images, clock feedthrough, noise floor).
- iCE40UP5K per-pin drive/current limit from the Lattice data sheet → series-R / buffer choice.
- Filter designs per band (post-measurement), attenuator, and any PA stage.
- On-air validation: `wsprd` decode of a real transmission and a WSPRnet spot (plan §26/§38) —
  recorded in `docs/verification.md` once it happens.

## 9. Sources

- `doc/wspr_icebreaker_orchestrator_plan.md` §18, §19, §25, §35, §26, §38.
- `docs/spec.md` §6 (tone spacing), §7 (slot timing), §8 (clock), §9 (default RF 10 140 200 Hz,
  resolution), §11 (pins), §16 (PENDING-HARDWARE).
- `docs/protocol.md` §8 (Nyquist/folding caveat); `docs/architecture.md` §11 (constraint summary).
- `src/nco/nco.vhd`, `src/wspr/wspr_modulator.vhd` headers (folding, centered grid, increments).
- WSJT-X 2.7.0+repack: `models/FrequencyList.cpp` (default WSPR dial frequencies),
  `widgets/mainwindow.cpp` (1500 Hz WSPR audio default; RF = dial + 1500).
- `tools/calculate_nco.py` (all carrier increments and achieved errors in §2, run at
  `--clock-hz 12000000`) and `tools/check_tone_order.py` (numeric verification of the tone-order
  rule in §1).
- ZOH/sinc image model: standard 1-bit-DAC theory, applied here as a first-order estimate —
  **measurement pending** (§8).
