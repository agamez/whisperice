# reference/ — Independent WSPR reference material

This directory holds Agent E's **independent** Python WSPR reference model
(`wspr_reference.py`) and the frozen golden test vectors (`test_vectors/`).
Both are bench/simulation material only — see the legal warning below.

## Independence statement (plan §1.1, §20, §28 Agent E)

`wspr_reference.py` is an **independent re-implementation**, written only from
the frozen constants and algorithms in [`docs/spec.md`](../docs/spec.md)
(§2 source encoding, §3 FEC, §4 interleaving, §5 sync/symbols, §6–§9
timing/frequency). It was **not ported from, linked against, or copied from the
WSJT-X source tree**; every constant carries a `docs/spec.md` citation in the
code. The pinned WSJT-X 2.7.0 tools are used only as an *external control* on
the result:

- `/usr/bin/wsprcode` — reference **encoder**, compared bit-for-bit;
- `/usr/bin/wsprd` — reference **decoder**, used by later phases on waveforms
  (not by this script).

A model that reproduced WSJT-X by porting it would prove nothing; the value of
this model is that it reaches the same 162 channel symbols from the frozen spec
alone. The comparison is one-directional (model → reference output) and the
reference output is recorded verbatim in the vector file.

## Runtime

- Python 3.13 with numpy 2.2.4 (OS package `python3-numpy`). No other packages.
- Reference tools from Debian package **wsjtx 2.7.0+repack-1** (WSJT-X 2.7.0).

## How to run the model

```sh
# Full report: payload bytes/bits, FEC input, coded, interleaved, sync,
# channel symbols (0..3) and the four tone frequencies.
python3 reference/wspr_reference.py "K1ABC FN42 37"

# Choose a different RF carrier for the tone table (default 10140200 Hz, §9).
python3 reference/wspr_reference.py --rf-frequency 28124600 "K1ABC FN42 37"

# Emit only the frozen-vector body (the sections used in test_vectors/*.txt).
python3 reference/wspr_reference.py --vector "K1ABC FN42 37"

# Self-test: structural checks + golden known-answer vectors + live wsprcode.
python3 reference/wspr_reference.py --self-test
python3 reference/wspr_reference.py --self-test --wsprcode /usr/bin/wsprcode

# Cross-check one message against the installed reference encoder.
python3 reference/wspr_reference.py --compare-wsprcode "K1ABC FN42 37"

# Negative control: flip one symbol and show the comparison detects it.
python3 reference/wspr_reference.py --negative-control "K1ABC FN42 37" \
        --wsprcode /usr/bin/wsprcode
```

The chain implemented is, in order: source-encode 50 bits (§2) → append 31 zero
tail bits = 81 FEC input bits (§3) → K=32 r=1/2 Layland–Lushbaugh convolutional
code = 162 coded bits (§3) → bit-reversal interleaver = 162 interleaved bits
(§4) → `symbol = 2*data_bit + sync_bit` = 162 symbols in 0..3 (§5) → four tones
at `(tone-1.5) × 12000/8192 Hz` about the carrier (§6).

## Accepted and rejected message forms

Only the standard **WSPR Type-1** textual form is accepted:

```text
CALLSIGN GRID4 POWER_dBm
```

- `CALLSIGN` — 3..6 characters, A–Z/0–9, with a digit in the 2nd or 3rd
  position (e.g. `K1ABC` → aligned to `" K1ABC"`, `AB1C`, `VK2ABC`).
  Case is normalised to upper case.
- `GRID4` — a 4-character Maidenhead locator: letters `A`–`R` twice, then
  digits `0`–`9` twice (e.g. `FN42`).
- `POWER_dBm` — integer `0`..`60`.

Invalid input is **rejected with a clear error** (exit status 2) instead of
being silently encoded as garbage: a missing/extra field, a callsign without a
digit in position 2/3, a malformed locator, an out-of-range power, a packed
value that overflows its field, or any `/`, `<`, `>` (Type-2/Type-3 message
forms are outside this model's scope).

## Golden test vectors

`test_vectors/k1abc_fn42_37.txt` is the frozen bench vector for
`K1ABC FN42 37` (plan §20 minimum test; §0.1 bench-only). It contains a
provenance header with the **verbatim `/usr/bin/wsprcode` output** and the
independent model's sections: `PAYLOAD BITS (50)`, `CODED BITS (162)`,
`INTERLEAVED (162)`, `SYNC (162)`, `SYMBOLS (162)`, `TONES`.

It was generated with:

```sh
python3 reference/wspr_reference.py --vector "K1ABC FN42 37"
```

and cross-checked with:

```sh
python3 reference/wspr_reference.py --compare-wsprcode "K1ABC FN42 37"
# -> 0/162 channel-symbol differences vs /usr/bin/wsprcode (WSJT-X 2.7.0)
```

The packed 50-bit payload is `F7 0C 23 8B 0D 19 40`, matching `docs/spec.md`
§2 (`n = 259047992 = 0x0F70C238`, `m = 2896997 = 0x2C3465`).

### Additional vectors (exercised by `--self-test`)

Two further messages are embedded as known-answer vectors in
`wspr_reference.py` and re-checked against the golden strings (which are the
verbatim `wsprcode` output) on every `--self-test` run:

| Message | Payload bytes | Reference |
|---|---|---|
| `K1ABC FN42 37` | `F7 0C 23 8B 0D 19 40` | `wsprcode` 0/162 |
| `K1ABC FN42 27` | `F7 0C 23 8B 0D 16 C0` | `wsprcode` 0/162 |
| `VK2ABC QF56 37` | `D5 47 30 31 42 19 40` | `wsprcode` 0/162 |

`K1ABC FN42 27` exercises a different power (27 dBm) and a different tail byte;
`VK2ABC QF56 37` exercises a 6-character callsign with a digit in the 3rd
position (no shift/pad) and a different grid. All three pass with
**0/162** differences against `/usr/bin/wsprcode`.

## Negative control (plan §20: "the test must fail on a single-bit difference")

`--negative-control` flips channel symbol 80 (mod 4) and reports the mismatch
against both the golden vector and the live reference encoder:

```text
negative control on 'K1ABC FN42 37'
  perturbed symbol index 80: 2 -> 3
  vs golden vector   : 1/162 differences at indices [80]
  vs wsprcode 2.7.0  : 1/162 differences at indices [80]
```

The same failure is observable through the self-test: corrupting one golden
symbol in a scratch copy makes `--self-test` fail with exactly one mismatching
vector while the live `wsprcode` cross-check still reports 0/162 — proving the
harness (not the encoder) is what detects the injected difference.

## Legal / bench-only warning

`K1ABC FN42 37` is a conventional documentation example. It must **never** be
radiated over the air (`docs/spec.md` §15; plan §0.1). Over-the-air operation
requires an amateur licence appropriate to the operator and jurisdiction, the
operator's own callsign, and compliance with the local band plan and power
limits.
