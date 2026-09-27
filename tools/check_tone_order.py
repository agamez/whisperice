#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verify the tone-order rule of docs/rf.md section 1.

docs/rf.md claims, for a carrier above Nyquist (e.g. the 30 m default at a
12 MHz sample clock):
  * the analog line at the carrier frequency itself (10.1402 MHz) carries the
    4-FSK tones in the CORRECT order, and
  * the folded line at (f_clk - carrier) = 1.8598 MHz is ~15 dB stronger but
    tone-INVERTED, hence unusable for WSPR.

This script measures both claims on a zero-order-hold staircase built from the
REAL 40-bit increments of tools/calculate_nco.py (no approximated phases):
it accumulates the phase for tone 0 and tone 3, takes the MSB (the actual
1-bit pin sequence), holds each sample 8x (ZOH), and projects the spectrum at
the exact line frequencies.  Expected result:
    RF image line: order CORRECT
    Fold line:     order INVERTED
    fold/RF amplitude ratio ~ +14.6 dB  (sinc model: 0.9619/0.1762 = +14.75 dB)

Usage:  python3 tools/check_tone_order.py          (~10 s, numpy only)
"""
import numpy as np

FCLK = 12e6
L = 8                       # ZOH oversampling: analog "sample rate" 96 MHz
N = 2**20                   # samples at fclk (~87 ms)
INC = {0: 929105449338,     # tone 0 (RF 10 140 197.802734375 Hz)
       3: 929105851991}     # tone 3 (RF 10 140 202.197265625 Hz)
RF_LO, RF_HI = 10140197.802734375, 10140202.197265625
FOLD_HI, FOLD_LO = 1859802.197265625, 1859797.802734375


def amp_at(x, fs, f_target):
    """Single-bin DFT magnitude at the exact frequency (Goertzel-style)."""
    n = np.arange(len(x))
    return np.abs(np.dot(x, np.exp(-2j * np.pi * f_target * n / fs))) / len(x)


def measure(increment):
    acc = (np.cumsum(np.full(N, increment, dtype=np.uint64))
           & ((1 << 40) - 1)).astype(np.uint64)
    msb = ((acc >> 39) & 1).astype(np.float64)
    zoh = np.repeat(msb, L)                       # staircase (ZOH)
    zoh = zoh - zoh.mean()                        # drop DC
    fs = FCLK * L
    return {f: amp_at(zoh, fs, f) for f in (RF_LO, RF_HI, FOLD_HI, FOLD_LO)}


def main():
    m0, m3 = measure(INC[0]), measure(INC[3])
    print("amplitudes at the exact line frequencies:")
    print(f"  tone0 (inc0): RF@{RF_LO:.1f} = {m0[RF_LO]:.3e}"
          f"   RF@{RF_HI:.1f} = {m0[RF_HI]:.3e}"
          f"   fold@{FOLD_HI:.1f} = {m0[FOLD_HI]:.3e}"
          f"   fold@{FOLD_LO:.1f} = {m0[FOLD_LO]:.3e}")
    print(f"  tone3 (inc3): RF@{RF_LO:.1f} = {m3[RF_LO]:.3e}"
          f"   RF@{RF_HI:.1f} = {m3[RF_HI]:.3e}"
          f"   fold@{FOLD_HI:.1f} = {m3[FOLD_HI]:.3e}"
          f"   fold@{FOLD_LO:.1f} = {m3[FOLD_LO]:.3e}")
    print()
    ok_rf = m0[RF_LO] > m0[RF_HI] and m3[RF_HI] > m3[RF_LO]
    ok_fold = m0[FOLD_HI] > m0[FOLD_LO] and m3[FOLD_LO] > m3[FOLD_HI]
    print("RF image line: tone0 strongest at the lower RF?", m0[RF_LO] > m0[RF_HI],
          "| tone3 strongest at the higher RF?", m3[RF_HI] > m3[RF_LO],
          "=> order", "CORRECT" if ok_rf else "WRONG")
    print("Fold line:     tone0 strongest at the higher fold?", m0[FOLD_HI] > m0[FOLD_LO],
          "| tone3 strongest at the lower fold?", m3[FOLD_LO] > m3[FOLD_HI],
          "=> order", "INVERTED (as documented)" if ok_fold else "UNEXPECTED")
    ratio_db = 20 * np.log10((m0[FOLD_HI] + m3[FOLD_LO]) / (m0[RF_LO] + m3[RF_HI]))
    print(f"fold/RF amplitude ratio: {ratio_db:+.1f} dB"
          " (sinc first-order model: +14.75 dB, fold stronger)")
    if not (ok_rf and ok_fold):
        raise SystemExit("FAILED: measured tone order contradicts docs/rf.md")


if __name__ == "__main__":
    main()
