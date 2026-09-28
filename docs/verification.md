# Verification record — wspr-icebreaker

> The project's acceptance criterion is a **standard decoder decoding a real transmission**
> (plan §26, §30-H, §38). This document records the verification evidence: what was verified,
> with which pinned tools, the exact commands, and the results. Items that need the physical
> board are marked **PENDING-HARDWARE** (spec §16).

## 1. Status summary

| Layer | Evidence | Result | Recorded in |
|---|---|---|---|
| Codec vs pinned encoder | `wspr_reference.py --self-test` (0/162 vs `wsprcode`, 3 messages) | PASS | `reference/README.md`, spec §15 |
| RTL per-block | 13 testbenches (`make sim`) | 13/13 PASS | `architecture.md` §12, `gps.md` |
| RTL integration incl. tone identity | `tb_wspr_top` (all 162 symbols vs `TONE_GOLDEN`) | PASS | review §3 M7, `review-pedagogical.md` |
| Bitstream | `make clean && make` → `build/top.bin`, icetime 31.09 MHz | PASS | `architecture.md` §12 |
| **Decoder adjudication (synthetic)** | **`wsprd` 2.7.0 decodes the golden chain from a synthesized WAV** | **PASS — §3** | **this document** |
| Decoder adjudication (real RF) | on-air TX → `wsprd` → WSPRnet spot | PENDING-HARDWARE | §5 |

## 2. End-to-end decoder adjudication — synthetic WAV (reproduces spec §7.3)

Phase 0 froze the TX-start offset using this experiment (spec §7.3). The tool
[`tools/make_wspr_wav.py`](../tools/make_wspr_wav.py) re-runs it as a committed, reproducible
artifact; the full method and every constant citation are in the tool's header. In brief:

- the golden chain (`reference/wspr_reference.py`, 0/162 vs `wsprcode`) produces the 162 channel
  symbols for the bench message "K1ABC FN42 37" — **simulation vector, never radiate (plan §25)**;
- a continuous-phase 4-FSK signal at the 1500 Hz audio centre (tone k at
  `1500 + (k − 1.5)·12000/8192` Hz, exactly 8192 samples per symbol) is written to a
  120 s / 12 kHz / 16-bit mono WAV — the format `wsprd`'s `readwavfile` expects
  (`lib/wsprd/wsprd.c:109-178`: 44-byte header ignored, raw shorts, 12 kHz assumed, first 114 s
  consumed);
- the pinned decoder `/usr/bin/wsprd` (Debian `wsjtx 2.7.0+repack-1`) decodes the file.

### Commands

```sh
# (if your shell sources the oss-cad-suite profile, use /usr/bin/python3 —
#  see docs/environment.md, numpy PATH caveat)
python3 tools/make_wspr_wav.py --start 1.0 --out /tmp/260101_0001.wav
python3 tools/make_wspr_wav.py --start 2.0 --out /tmp/260101_0002.wav
cd /tmp && wsprd -v -f 10.140210 260101_0001.wav
wsprd -v -f 10.140210 260101_0002.wav
```

(The `YYMMDD_HHMM` file names are synthetic labels; `wsprd` parses date/time fields from the file
name — `wsprd.c:966-967` — and prints them as the first column of each decode line.)

### Results (verbatim, 2026-09-27)

TX placed at **1.000 s** into the file:

```text
0001   8 -0.0  10.141709  0  K1ABC FN42 37
0001  12 -0.0  10.141710  0  K1ABC FN42 37
0001  40 -0.0  10.141710  0  K1ABC FN42 37
0001  11  0.1  10.141710  0  K1ABC FN42 37
```

TX placed at **2.000 s**:

```text
0002  -7  1.0  10.141709  0  K1ABC FN42 37
0002  -3  1.0  10.141710  0  K1ABC FN42 37
0002  40  1.0  10.141710  0  K1ABC FN42 37
0002  -3  1.2  10.141710  0  K1ABC FN42 37
0002  -7  1.0  10.141712  0  K1ABC FN42 37
```

Decode-line columns: `<file HHMM> <sync dB> <DT s> <freq MHz> <drift Hz/min> <message>`.

### Adjudication

| Check | Expectation (spec §7.3) | Measured | Verdict |
|---|---|---|---|
| Decode of the golden chain | `K1ABC FN42 37` | both files, every pass | **PASS** |
| DT for a TX at 1.000 s | ≈ 0 (−0.0 / 0.1) | −0.0 / 0.1 | **PASS** |
| DT for a TX at 2.000 s | ≈ +1.0 (1.0 / 1.2) | 1.0 / 1.2 | **PASS** |
| Frequency | dial + 1.5 kHz = 10.141710 | 10.141709 / 10.141710 | **PASS** |
| Drift | 0 (no drift modeled) | 0 | **PASS** |

This adjudicates, without hardware:

1. **The codec chain end to end** — message → payload → FEC → interleave → sync → channel
   symbols → modulated audio → standard decoder → original message.
2. **The DT convention** — `wsprd` prints `DT = TX_start_in_file − 1.0 s` (frozen in spec §7;
   the "nominal start 2 seconds into the file … DT = shift-2 s" comment at `wsprd.c:1136-1145`
   is stale, exactly as documented in spec §7).
3. **The synthesis principles are decoder-compatible** — continuous phase across symbol
   boundaries, the centered tone grid, and 8192-sample symbol timing are the same principles the
   RTL modulator implements (`wspr_modulator.vhd`; plan §16/§17).

What it does **not** adjudicate (PENDING-HARDWARE): the RTL's actual 1-bit GPIO output on real
silicon, the RF chain of [`docs/rf.md`](rf.md), and over-the-air reception.

## 3. RTL functional verification

- `make sim` — 13/13 testbenches PASS (`tb_wspr_top`, `tb_gps_*`, `tb_pps_measure`,
  `tb_clock_calibration`, `tb_nco`, `tb_wspr_message/fec/interleave/symbols/modulator`,
  `tb_wspr_scheduler`). Per-block coverage and negative paths: `docs/gps.md`,
  `architecture.md` §12.
- Integration tone identity (review finding M7): `tb_wspr_top` verifies all 162 transmitted
  symbol classes against `TONE_GOLDEN` (the M1 regression check) and the exact transition total
  (679 935 measured vs 679 936 expected).
- `make clean && make` — bitstream builds error-free; icetime PASS at 31.09 MHz (≥ 12 MHz
  requirement).
- Strict VHDL-93 sweep: `ghdl -a --std=93 -fexplicit -Wbinding` rc=0 on every RTL and TB file
  (`review-pedagogical.md` §2/§6).

## 4. Tools

| Tool | Purpose |
|---|---|
| `reference/wspr_reference.py` | independent golden model (`--self-test`, `--vector`) |
| `tools/calculate_nco.py` | NCO increment provenance for any carrier |
| `tools/check_tone_order.py` | numeric proof of the `docs/rf.md` tone-order rule |
| `tools/make_wspr_wav.py` | synthetic-WAV generator for decoder adjudication (§2) |

## 5. Hardware adjudication plan (PENDING-HARDWARE, spec §16)

> The complete runbook for the agent with hardware access — machine setup, ratification
> checklist, staged bring-up, feedback loop and stop-gates — is
> [`docs/hardware.md`](hardware.md). The plan below is the summary; the runbook is the procedure.

1. Environment: `lsusb | grep 0403:6010`, `iceprog -t` against the board; record in
   `docs/environment.md` §4.
2. Bench TX into a **50 Ω dummy load** (never an antenna; plan §25): capture `rf_out` with a
   scope/SA or an SDR; compare the measured spectrum against the `docs/rf.md` §1/§2 model
   (fundamental, images, 12 MHz feedthrough) and ratify the RF pin.
3. Loop the captured audio through `wsprd` exactly as in §2 — the RTL's own transmission must
   decode `K1ABC FN42 37` (bench message) with DT ≈ 0 for a slot-anchored capture.
4. GPS bring-up per `docs/gps.md`: NMEA sentence inventory, 1PPS pulse width, ~2.8 V I/O levels.
5. Only then, licensed and with the operator's callsign compiled in: attenuated OTA test →
   `wsprd` decode by a remote receiver → WSPRnet spot (plan §26/§38). Record date, spot link,
   SNR, and the configuration used here.

## 6. Sources

- `docs/spec.md` §7 (TX-start resolution), §7.3 (the experiment reproduced in §2), §15
  (golden vector), §16 (PENDING-HARDWARE).
- `lib/wsprd/wsprd.c:109-178` (WAV format), `:1136-1145` (DT search, stale comment),
  `:966-967` (file-name date/time parsing); `lib/wsprd/wsprsim.c` (`add_signal_vector`,
  continuous-phase synthesis); `lib/wsprd/wsprsimf.f90:67-73` (centered tone offsets).
- `reference/README.md` (codec cross-check), `docs/rf.md` (RF chain), `review-pedagogical.md`
  (review verification table).
