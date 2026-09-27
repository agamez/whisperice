#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Provenance tool for the NCO increment constants (RTL / config).

This script converts an RF frequency and an FPGA clock frequency into the
40-bit phase increment used by ``src/nco/nco.vhd`` and by the WSPR modulator,
exactly and reproducibly.  It is the single source of truth for the integer
constants that are pasted into RTL/simulation (no floating-point arithmetic is
used in the datapath -- plan section 9).

Definitions
-----------
A phase-accumulator NCO whose top bit is the output produces

    f_out = increment * clock_hz / 2**ACCUMULATOR_BITS

so the increment for a wanted frequency is

    increment = round(f * 2**ACCUMULATOR_BITS / clock_hz).

``docs/spec.md`` section 8 freezes ``ACCUMULATOR_BITS = 40`` and ``clock =
12 MHz`` (resolution ``12e6 / 2**40 ~ 1.0914e-5 Hz``).  Section 9 freezes the
default RF carrier ``DEFAULT_RF_FREQUENCY_HZ = 10140200`` (30 m WSPR segment
centre, DEFAULT-CONFIGURABLE).  WSPR tone spacing is ``12000/8192 =
1.46484375 Hz`` (section 6); the four tone increments are carrier + k * spacing
for k = 0..3 (plan section 9).

All arithmetic here is exact integer / rational (``fractions.Fraction``); the
decimal output is for readability only.  Rounding is round-half-up, the
convention used consistently across the project.

Usage
-----
    python3 tools/calculate_nco.py
    python3 tools/calculate_nco.py --clock-hz 12000000 --frequency 10140200

Everything in this file is bench/design tooling; it produces no RF and is not
part of the transmit path (AGENTS.md section 2.5).
"""

from __future__ import annotations

import argparse
import decimal
from decimal import Decimal
from fractions import Fraction

# Frozen constants (docs/spec.md sections 6/8/9; plan sections 8/9).
ACCUMULATOR_BITS = 40
DEFAULT_CLOCK_HZ = 12_000_000
DEFAULT_RF_FREQUENCY_HZ = 10140200
TONE_SPACING_HZ = Fraction(12000, 8192)  # 1.46484375 Hz exactly (spec section 6)

TWO_POW_BITS = 1 << ACCUMULATOR_BITS


def round_half_up(value: Fraction) -> int:
    """Round a Fraction to the nearest integer, halves away from zero."""
    n, d = value.numerator, value.denominator
    if n >= 0:
        return (2 * n + d) // (2 * d)
    return -((-2 * n + d) // (2 * d))


def increment_for(frequency_hz: Fraction, clock_hz: Fraction) -> int:
    """Exact 40-bit phase increment for ``frequency_hz`` at ``clock_hz``."""
    return round_half_up(Fraction(frequency_hz) * TWO_POW_BITS / Fraction(clock_hz))


def achieved_hz(increment: int, clock_hz: Fraction) -> Fraction:
    """Exact frequency produced by ``increment`` at ``clock_hz``."""
    return Fraction(increment) * Fraction(clock_hz) / TWO_POW_BITS


def dec(value: Fraction, places: int = 12) -> str:
    """Format a Fraction as a fixed-point decimal string (display only)."""
    with decimal.localcontext() as ctx:
        ctx.prec = places + 20
        d = Decimal(value.numerator) / Decimal(value.denominator)
        return f"{d:.{places}f}"


def parse_frequency(text: str) -> Fraction:
    """Parse an integer or decimal frequency string exactly."""
    return Fraction(text)


def describe(label: str, frequency: Fraction, clock: Fraction, places: int) -> str:
    inc = increment_for(frequency, clock)
    got = achieved_hz(inc, clock)
    err = got - frequency
    sign = "+" if err >= 0 else "-"
    return (
        f"  {label:<10} target={dec(frequency, places)} Hz  "
        f"increment={inc} (0x{inc:010x})  "
        f"achieved={dec(got, places)} Hz  "
        f"error={sign}{dec(abs(err), places)} Hz"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compute 40-bit NCO phase increments (provenance tool)."
    )
    parser.add_argument(
        "--clock-hz",
        type=parse_frequency,
        default=Fraction(DEFAULT_CLOCK_HZ),
        help="FPGA clock frequency in Hz (default: %(default)s)",
    )
    parser.add_argument(
        "--frequency",
        type=parse_frequency,
        default=Fraction(DEFAULT_RF_FREQUENCY_HZ),
        help="RF carrier frequency in Hz (default: %(default)s)",
    )
    parser.add_argument(
        "--decimals",
        type=int,
        default=9,
        help="decimal places in the achieved/error display (default: %(default)s)",
    )
    args = parser.parse_args()

    clock: Fraction = args.clock_hz
    carrier: Fraction = args.frequency
    resolution = clock / TWO_POW_BITS

    print("NCO increment calculator -- provenance for the RTL constants")
    print("  docs/spec.md sections 5/6/8/9; plan sections 8/9")
    print()
    print(f"  clock                 : {clock} Hz")
    print(f"  accumulator bits      : {ACCUMULATOR_BITS}")
    print(f"  frequency resolution  : {dec(resolution, 15)} Hz"
          f"  (clock / 2**{ACCUMULATOR_BITS})")
    print(f"  WSPR tone spacing     : {TONE_SPACING_HZ} Hz  (12000/8192)")
    print()
    print(f"  RF carrier (default)  : {dec(carrier, args.decimals)} Hz")
    print(describe("carrier", carrier, clock, args.decimals))
    print()
    print("  WSPR tones: carrier + k * spacing, k = 0..3")
    for k in range(4):
        freq = carrier + k * TONE_SPACING_HZ
        print(describe(f"tone[{k}]", freq, clock, args.decimals))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
