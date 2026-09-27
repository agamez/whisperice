# WSPR protocol contract — wspr-icebreaker

> **Frozen.** Every constant below is restated from [`docs/spec.md`](spec.md) §2–§9 with its primary
> citation. The pinned reference implementation is **WSJT-X 2.7.0** (Debian `wsjtx 2.7.0+repack-1`;
> source tree `/tmp/opencode/wsjtx-src/wsjtx-2.7.0+repack/`, orig tarball SHA256
> `c4687b322ed36d3c526ed32e99ea48023eb76542c004a0d4658e58d8ddbf3538`, `docs/environment.md` §3.3).
> All `file:line` citations below refer to that tree and are carried verbatim from `docs/spec.md`.
> **Change control:** any change to a constant in §1–§8 triggers a re-review of the test vectors
> (plan §29 Rule 5 / `AGENTS.md` §5); no approximation without explicit, documented justification
> (plan §29 Rule 6).

## 1. Message form and source encoding (50 bits)

WSPR **Type 1**: `CALLSIGN GRID4 POWER_dBm` (spec §2; plan §13.1; `lib/wsprd/wsprsim_utils.c:199-211`).
Type 2/3 are out of scope until Type 1 is fully verified (plan §13.1).

| Field | Width | Citation |
|---|---|---|
| Callsign | **28 bits** | spec §2; `lib/wsprd/wsprsim_utils.c:50-79` |
| Grid (Maidenhead 4-char) | **15 bits** | spec §2; `lib/wsprd/wsprsim_utils.c:42-48` |
| Power (dBm) | **7 bits** | spec §2; `lib/wsprd/wsprsim_utils.c:42-48` |
| **Payload** | **50 bits** (28+15+7) | plan §13.2/§37; `lib/wsprd/WSPRcode.f90:94` |

**Callsign packing.** Pad/align to exactly 6 characters: if the 3rd character is a digit, use as-is;
else if the 2nd is a digit, left-shift one and pad a leading space (`lib/wsprd/wsprsim_utils.c:53-71`).
Character codes `'0'..'9'`→0..9, `' '`→36, `'A'..'Z'`→10..35 (`get_callsign_character_code`,
`lib/wsprd/wsprsim_utils.c:29-40`), then `n = 36*c0; n = 36*n + c1; n = 10*n + c2; n = 27*n +
(c3-10); n = 27*n + (c4-10); n = 27*n + (c5-10)` (`lib/wsprd/wsprsim_utils.c:72-77`).

**Grid + power packing.** Locator codes `'0'..'9'`→0..9, `' '`→36, `'A'..'R'`→0..17
(`get_locator_character_code`, `lib/wsprd/wsprsim_utils.c:16-27`). For grid `g0 g1 g2 g3`,
`m = ((179 - 10*g0 - g2)*180 + 10*g1 + g3)*128 + power + 64`
(`pack_grid4_power`, `lib/wsprd/wsprsim_utils.c:42-48`).

**Bit assembly.** 50 payload bits packed MSB-first into `data[0..6]`, followed by **31 tail bits = 0**
(zero-filled `data[7..10]`), `lib/wsprd/wsprsim_utils.c:255-275`:

```text
data[0]= n>>20     data[1]= n>>12     data[2]= n>>4
data[3]= ((n&0x0F)<<4) + ((m>>18)&0x0F)
data[4]= m>>10     data[5]= m>>2      data[6]= (m&0x03)<<6
data[7..10] = 0
```

## 2. Forward error correction (FEC)

| Constant | Frozen value | Citation |
|---|---|---|
| Constraint length | **K = 32** | spec §3; `lib/wsprd/WSPRcode.f90:94`; `lib/encode232.f90:3` |
| Code rate | **r = 1/2** | spec §3; idem |
| FEC input | 50 payload + **31 tail zeros = 81** bits | spec §3; `lib/wsprd/WSPRcode.f90:94` (`nbits=50+31`) |
| Coded bits (used) | **162** | spec §3; `lib/wsprd/WSPRcode.f90:7` |
| Code | Layland–Lushbaugh, non-systematic | spec §3; `lib/wsprd/fano.c:13` (`#define LL 1`), `:46-52` |
| POLY1 | **`0xf2d05351`** (= decimal `-221228207`) | spec §3; `lib/wsprd/fano.c:50`; `lib/conv232.f90:4`; `lib/wsprcode/wspr_old_subs.f90:69` |
| POLY2 | **`0xe4613c47`** (= decimal `-463389625`) | spec §3; `lib/wsprd/fano.c:51`; `lib/conv232.f90:4`; `lib/wsprcode/wspr_old_subs.f90:69` |

Bit-order conventions that must be reproduced exactly (spec §3): input bytes are consumed **MSB
first** (`lib/wsprd/fano.c:72-74`); state is a **32-bit shift register, newest input bit in the LSB**
(`encstate = (encstate << 1) | bit`, `lib/wsprd/fano.c:74`); per input bit, output **POLY1 parity
first, then POLY2** (`lib/wsprd/fano.c:76-77`); parity is the even parity of the 32-bit `state & POLY`
(the reference folds it with two XOR-shifts into a 256-entry even-parity table — algebraically
identical, `lib/wsprd/fano.h:28-37`); one coded bit per byte is emitted (`lib/wsprd/fano.c:59-60`),
`encode()` runs over 11 bytes (88 bits) and the first **162** are used
(`lib/wsprd/wsprsim_utils.c:298-302`). The alternative "NASA standard" and "MJ" polynomial defines are
inactive; the active branch is `LL` (`lib/wsprd/fano.c:28-52`).

## 3. Interleaving

Frozen bit-reversal interleaver (spec §4). Build the 162-entry index table `j0` from the **bit-reversal
of the 8-bit index**: for `i = 0..255`, compute `n = bitreverse8(i)` and keep `n` when `n ≤ 161`, in
increasing-`i` order; `j0` is then a permutation of `0..161`. Encoder (interleave): `itmp[j0(i)] =
id(i)` — `lib/inter_wspr.f90:30-33` (C equivalent `lib/wsprd/wsprsim_utils.c:152-159`). Decoder
(de-interleave): `itmp(i) = id(j0(i))` — `lib/inter_wspr.f90:34-37` (C equivalent
`lib/wsprd/wsprd_utils.c:214-219`). **No "equivalent" permutation may be substituted** (plan §15). The
Phase-0 generator reproduced `wsprcode` channel symbols bit-for-bit, **0/162 differences** (spec §4;
`reference/README.md`).

## 4. Synchronisation vector and symbol combination

| Constant | Frozen value | Citation |
|---|---|---|
| Sync vector length | **162 bits** | spec §5; `lib/wsprd/WSPRcode.f90:7,15-26` |
| Source of truth (FORTRAN) | `sync(162)` data statement | `lib/wsprd/WSPRcode.f90:17-26` |
| Same vector (TX) | `npr3(162)` | `lib/genwspr.f90:9-19` |
| Same vector (C, RX) | `pr3[162]` | `lib/wsprd/wsprd.c:55-63`; `lib/wsprd/wsprsim_utils.c:169-178` |
| **Combination rule** | **`tone_symbol = 2*data_bit + sync_bit`** → {0,1,2,3} | spec §5; `lib/wsprd/WSPRcode.f90:118`; `lib/genwspr.f90:24-26`; `lib/wsprd/wsprsim_utils.c:306-308` |

The frozen vector is printed in spec §5 (`lib/wsprd/WSPRcode.f90:17-26`) and stored as a single named
constant in `src/wspr/wspr_sync.vhd`. `data_bit` is one interleaved FEC output bit (§3) per symbol.

## 5. Modulation and timing

| Constant | Frozen value | Exact expression | Citation |
|---|---|---|---|
| Tone spacing | **1.46484375 Hz** | `12000/8192` Hz | spec §6; `lib/wsprd/wsprd.c:209` (`df=375.0/256.0`); `lib/wsprd/wsprsimf.f90:47` |
| Symbol duration | **8192/12000 s** ≈ 0.68266… s | `8192/12000` | spec §6; `lib/wsprd/wsprd.c:209,276` |
| Number of symbols | **162** | — | spec §6; `lib/wsprd/WSPRcode.f90:7` |
| TX duration | **110.592 s** (exact) | `162 × 8192/12000` | plan §10/§37; spec §6 |
| Slot length | **120 s**, even UTC minute | — | spec §6; `widgets/mainwindow.cpp:8142` (`m_TRperiod=120.0`) |
| Tone offsets from carrier `f0` | `-1.5, -0.5, +0.5, +1.5` × spacing, tones 0..3 | `(tone-1.5)*baud` | spec §6; `lib/wsprd/wsprsimf.f90:67-73`; `lib/wsprd/wsprd.c:234-250` |
| Modulation | continuous-phase 4-FSK, single accumulated phase, 1-bit GPIO | — | plan §16–§18 |

Bench audio convention: nominal centre **1500 Hz** on a USB dial frequency; `wsprd` downconverts around
1500 Hz (`lib/wsprd/wsprd.c:118-127`); WSJT-X default WSPR audio Tx is 1500 Hz
(`widgets/mainwindow.cpp:1487`). Timing accumulates the exact fraction — never a rounded "683 ms"
(plan §10).

## 6. TX start offset within the even minute — RESOLVED

> **FROZEN: the first WSPR symbol starts at +1.000 s after 00:00.000 of the even UTC minute.** The
> signal occupies +1.000 s … +111.592 s of the 120 s slot. This is the decoder-facing and
> scheduler-facing value. The "2 s" wording in a stale source comment and in some secondary references
> (e.g. ARRL; plan §0.1) is **not** used.

**Scheduler side (WSJT-X 2.7.0).** `widgets/mainwindow.cpp:5023-5029`: `nsec = ms/1000`, `nseq =
fmod(nsec, m_TRperiod)` with `m_TRperiod = 120.0` for WSPR (`widgets/mainwindow.cpp:8142`); UTC
midnight is an even minute, so `nseq == 0` occurs at the top of each even UTC minute.
`widgets/mainwindow.cpp:5038-5047`: for `m_mode == "WSPR"`, Tx/Rx is decided when `nseq == 0 and
m_ntr == 0`. `Modulator/Modulator.cpp:72`: `unsigned delay_ms = 1000;` — the WSPR default is
**1000 ms**; the overrides at `:73-76` apply only to FT8/FST4/FT4/Q65, **not** WSPR.
`Modulator/Modulator.cpp:87-100` and `:174-184`: silence frames are emitted first "so that audio will
start at the nominal time `delay_ms` into the Tx sequence". Therefore the first WSPR symbol starts
**1.000 s into the even UTC minute**.

**Decoder side (`wsprd` 2.7.0).** `lib/wsprd/wsprd.c:1455-1461`: `dt_print = shift1*dt - 1.0` (`dt =
1/375`, `lib/wsprd/wsprd.c:758`). Hence **DT = 0 means the signal started 1.0 s into the file**. The
comment at `lib/wsprd/wsprd.c:1136-1145` ("nominal start time, which is 2 seconds into the file";
"The program prints DT = shift-2 s") is **internally inconsistent with the executable code immediately
below it** and with the scheduler. It is the only surviving "2 s" statement.

**Empirical adjudication (Phase 0, `wsprd` 2.7.0).** A synthetic Type-1 `K1ABC FN42 37` signal encoded
with the exact §1–§3 algorithms (verified 0/162 against `/usr/bin/wsprcode`), placed at a known offset
in a 120 s / 12 kHz / 16-bit mono WAV and decoded with `/usr/bin/wsprd` 2.7.0 (spec §7.3):

| Signal start | `wsprd` reported DT | Command |
|---|---|---|
| **1.000 s** | **-0.0 / 0.1** (≈ 0) | `wsprd -v -f 10.140210 260927_1202.wav` |
| 2.000 s | 1.0 / 1.2 | `wsprd -v -f 10.140210 260927_1204.wav` |

Both decoded `K1ABC FN42 37` at 10.141710 MHz. The decoder's physical nominal start is therefore
**1.0 s**, confirming `dt_print = shift − 1.0` and the scheduler's `delay_ms = 1000`. The decoder is
the acceptance criterion (plan §30-H), and both its code and empirical behaviour give 1.0 s; the
scheduler independently gives 1.0 s. **Later phases must reference this section for the TX-start
offset** (plan §0.1/§37). RTL consequence: `gps_time.minute_even` is high for the whole even minute
and `wspr_scheduler` fires `tx_enable` at `second = 1` (`docs/gps.md`; `src/timing/wspr_scheduler.vhd`).

## 7. Golden benchmark vector

`K1ABC FN42 37` — bench/simulation vector only, **never radiated** (spec §15).

| Quantity | Value | Source |
|---|---|---|
| `n` (callsign) | `259047992` = `0x0F70C238` | spec §2; recomputed and matches `wsprcode` |
| `m` (grid + power) | `2896997` = `0x2C3465` | spec §2; idem |
| 50-bit payload bytes | `F7 0C 23 8B 0D 19 40` | spec §2; `/usr/bin/wsprcode "K1ABC FN42 37"` (WSJT-X 2.7.0) |
| 50-bit binary | `11110111 00001100 00100011 10001011 00001101 00011001 01` | spec §2 |
| Reference symbols (162) | `reference/test_vectors/k1abc_fn42_37.txt` | cross-checked **0/162** vs `/usr/bin/wsprcode`, Debian `wsjtx 2.7.0+repack-1` |

The vector file records the FEC input (81), coded (162), interleaved (162), sync (162), symbols (162)
and the four tone frequencies at the default carrier. The independent model
(`reference/wspr_reference.py`) is documented in `reference/README.md`.

## 8. RF frequency and band note

`DEFAULT_RF_FREQUENCY_HZ = 10140200` (30 m WSPR segment centre) is **DEFAULT-CONFIGURABLE, not a frozen
protocol constant** (spec §9); it may be overridden per band at build/config time. The RF output is a
single 1-bit pin sampled at `f_clk = 12 MHz`, so the highest fundamental it can represent is `f_clk/2 =
6 MHz`. The default 10.1402 MHz carrier is above Nyquist and folds to `12 MHz − 10.1402 MHz ≈ 1.86 MHz`
(spec §9; `nco.vhd`/`wspr_modulator.vhd` headers). **Band implication:** carriers below 6 MHz are
directly representable; WSPR **160 m (1 836.6 kHz) and 80 m (3 568.6 kHz)** are suitable for initial
tests, while **40 m (7 038.6 kHz) and higher need a faster output stage** (higher sample clock/SERDES or
an external mixer/filter). Filtering and harmonic removal are external-hardware responsibilities (plan
§19), flagged for `docs/rf.md` (currently a 0-byte placeholder).

Other standard WSPR dial frequencies (spec §9, for later multi-band work; not frozen): 60 m 5 287.2,
40 m 7 038.6, 30 m 10 138.7, 20 m 14 095.6, 17 m 18 104.6, 15 m 21 094.6, 12 m 24 924.6,
10 m 28 124.6 kHz (all USB dial).

## 9. Bench-only warning and legal requirement (binding)

`K1ABC FN42 37` is a **conventional documentation/bench vector only** and must **never** be radiated
over the air (spec §15; plan §0.1). Over-the-air transmission requires a valid amateur-radio licence
appropriate to the operator and jurisdiction, the operator's **own assigned callsign**, and compliance
with the local band plan and power limits (plan §25). The WSPR `power` field must reflect the **actual
radiated RF power**, not the GPIO logic level (plan §25; `AGENTS.md` §2.6).

## 10. Reference style

Short, frozen, numbered sections; every constant carries its primary WSJT-X 2.7.0 citation (or the
plan/spec section that does). Constants are restated here only to index them for later phases;
[`docs/spec.md`](spec.md) remains the authority and the RTL/test vectors are the verification
(plan §29 Rule 5).
