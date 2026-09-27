#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Synthesize a standard WSPR 2-minute WAV for decoder adjudication.

Reproduces -- as a committed, re-runnable tool -- the empirical experiment of
`docs/spec.md` section 7.3: a synthetic Type-1 "K1ABC FN42 37" signal is
encoded with the project's golden chain, written into a 120 s / 12 kHz /
16-bit mono WAV, and decodable by `/usr/bin/wsprd` (WSJT-X 2.7.0).

BENCH/SIMULATION ONLY -- the bench message must never be radiated (plan
section 25).

Method, with citations for every step:

* Audio format: 12 kHz, 16-bit signed little-endian mono PCM behind a standard
  44-byte RIFF header.  wsprd's `readwavfile` (lib/wsprd/wsprd.c:109-178)
  reads and IGNORES the 44-byte header (22 shorts), then reads raw shorts and
  assumes 12000 Hz (`df = 12000.0/nfft1`); samples are scaled by /32768.
* wsprd consumes only the first 114 s of the file (`npoints = 114*12000`,
  wsprd.c:122), so the transmission must start early enough to fit:
  start + 110.592 s <= 114 s.
* Channel symbols come from `reference/wspr_reference.py` (`encode_message`),
  the golden chain cross-checked 0/162 against `wsprcode`
  (reference/README.md; docs/spec.md section 15).
* Tone k occupies audio frequency `1500 + (k - 1.5) * (12000/8192)` Hz: the
  WSPR audio centre 1500 Hz (docs/spec.md section 6;
  `wspr_reference.AUDIO_CENTER_HZ`; wsprd downconverts around 1500 Hz,
  wsprd.c:118-127) plus the centered tone offsets `(tone - 1.5) * spacing`
  (lib/wsprd/wsprsimf.f90:67-73; docs/spec.md section 6).
* Continuous-phase synthesis: ONE accumulated phase across all 162 symbols --
  the same principle as the RTL modulator (plan sections 16/17) and the pinned
  simulator (`wsprsim.c`, `add_signal_vector`: phi += dphi per sample).
* Symbol timing: symbol k spans samples `[k*8192, (k+1)*8192)` -- exactly 8192
  samples at 12 kHz (symbol duration 8192/12000 s, docs/spec.md section 6).
* Timing convention: the transmission starts at `--start` seconds into the
  file.  Per the frozen empirical adjudication (docs/spec.md section 7.3,
  reproduced by this tool), wsprd prints `DT = file_start_of_TX - 1.0 s`:
  a TX starting at 1.000 s prints DT ~ 0.0.  (The source comment "nominal
  start time, which is 2 seconds into the file ... prints DT = shift-2 s",
  wsprd.c:1136-1145, is stale -- the same stale block that made the WSPR
  TX-start offset look like 2 s; docs/spec.md section 7.)

Usage:
    python3 tools/make_wspr_wav.py [--message "K1ABC FN42 37"] [--start 1.0]
                                   [--amplitude 0.25] [--duration 120]
                                   [--out FILE.wav]

Then decode:
    wsprd -v -f 10.140210 FILE.wav
"""
import argparse
import os
import sys
import wave

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, os.pardir, "reference"))

from wspr_reference import (  # noqa: E402
    AUDIO_CENTER_HZ,
    SYMBOL_COUNT,
    TONE_SPACING_HZ,
    encode_message,
)

# Audio sample rate.  wsprd assumes it (wsprd.c: `df = 12000.0/nfft1`); it is
# also the RTL's clock-derived reference, and it makes one symbol exactly
# 8192 samples.
SAMPLE_RATE_HZ = 12000

# Samples per WSPR symbol at 12 kHz: SYMBOL_DURATION_S * SAMPLE_RATE_HZ =
# (8192/12000)*12000 = 8192, an exact integer (docs/spec.md section 6).
SAMPLES_PER_SYMBOL = 8192


def synth(message: str, start_s: float, amplitude: float, duration_s: float):
    """Return (int16 samples, channel_symbols) for the requested placement."""
    encoded = encode_message(message)
    symbols = [int(s) for s in encoded.symbols]
    if len(symbols) != SYMBOL_COUNT:
        raise ValueError(f"expected {SYMBOL_COUNT} channel symbols, "
                         f"got {len(symbols)}")

    n_total = int(round(duration_s * SAMPLE_RATE_HZ))
    n_tx = SYMBOL_COUNT * SAMPLES_PER_SYMBOL          # 1,327,104 (110.592 s)
    start_sample = int(round(start_s * SAMPLE_RATE_HZ))
    if start_sample + n_tx > n_total:
        raise ValueError("transmission does not fit into the file duration")

    # Audio frequency of every TX sample: the centered 4-FSK grid around the
    # 1500 Hz audio centre (tone k at 1500 + (k - 1.5) * spacing).
    sym_index = np.arange(n_tx) // SAMPLES_PER_SYMBOL
    freqs = np.array([AUDIO_CENTER_HZ + (k - 1.5) * TONE_SPACING_HZ
                      for k in symbols])[sym_index]

    # Continuous phase: ONE accumulator across the whole transmission -- a
    # frequency step at a symbol boundary changes the increment, never the
    # phase (plan section 16; matches wspr_modulator.vhd and wsprsim.c).
    phase = 2.0 * np.pi * np.cumsum(freqs) / SAMPLE_RATE_HZ
    audio = amplitude * np.sin(phase)

    buf = np.zeros(n_total, dtype=np.float64)
    buf[start_sample:start_sample + n_tx] = audio
    return np.round(buf * 32767.0).astype(np.int16), symbols


def write_wav(path: str, samples: np.ndarray) -> None:
    """Write 16-bit mono PCM with a standard 44-byte RIFF header.

    wsprd skips the header wholesale (wsprd.c: "Read and ignore header"), but
    a well-formed file keeps the WAV usable in other tools (lessons, SDRs).
    """
    with wave.open(path, "wb") as w:
        w.setnchannels(1)                     # mono
        w.setsampwidth(2)                     # 16-bit signed
        w.setframerate(SAMPLE_RATE_HZ)        # 12000 Hz (assumed by wsprd)
        w.writeframes(samples.tobytes())


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--message", default="K1ABC FN42 37",
                   help="bench message (SIMULATION/BENCH ONLY -- never "
                        "radiate an example callsign, plan section 25)")
    p.add_argument("--start", type=float, default=1.0,
                   help="TX start time in seconds into the file (default 1.0; "
                        "wsprd then prints DT ~ 0.0, docs/spec.md section 7.3)")
    p.add_argument("--amplitude", type=float, default=0.25,
                   help="peak amplitude as a fraction of full scale")
    p.add_argument("--duration", type=float, default=120.0,
                   help="file duration in seconds (standard WSPR cycle)")
    p.add_argument("--out", default="wspr_bench.wav", help="output WAV path")
    args = p.parse_args(argv)

    samples, symbols = synth(args.message, args.start, args.amplitude,
                             args.duration)
    write_wav(args.out, samples)

    print(f"message            : {args.message}  (BENCH ONLY, never radiate)")
    print(f"channel symbols    : {len(symbols)} "
          f"(first 8: {' '.join(str(s) for s in symbols[:8])})")
    print(f"audio              : {SAMPLE_RATE_HZ} Hz, 16-bit mono, "
          f"{args.duration:.1f} s")
    print(f"TX start           : {args.start:.3f} s into the file")
    print(f"TX duration        : {SYMBOL_COUNT * SAMPLES_PER_SYMBOL} samples "
          f"= {SYMBOL_COUNT * SAMPLES_PER_SYMBOL / SAMPLE_RATE_HZ:.3f} s")
    print(f"expected wsprd DT  : {args.start - 1.0:+.3f} "
          f"(DT = TX start - 1.0 s, docs/spec.md section 7.3)")
    print(f"written            : {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
