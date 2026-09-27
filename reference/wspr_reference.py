#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Independent WSPR Type-1 encoder reference model (Agent E, Phase 16).

This is an INDEPENDENT re-implementation of the WSPR transmit chain.  It was
written from the frozen constants in ``docs/spec.md`` (Phase 0, status FROZEN)
and **not** ported from the WSJT-X sources.  As an external control the final
162 channel symbols are compared bit-for-bit against the pinned reference
encoder ``/usr/bin/wsprcode`` from Debian ``wsjtx 2.7.0+repack-1`` (upstream
WSJT-X 2.7.0); see ``--compare-wsprcode`` and ``reference/README.md``.

Chain (plan section 20 / Phase 16):

    message -> 50-bit payload -> +31 zero tail -> 162 coded bits
            -> 162 interleaved bits -> 162 channel symbols -> 4 tones

Usage::

    python3 reference/wspr_reference.py "K1ABC FN42 37"
    python3 reference/wspr_reference.py --self-test
    python3 reference/wspr_reference.py --compare-wsprcode "K1ABC FN42 37"
    python3 reference/wspr_reference.py --vector "K1ABC FN42 37"
    python3 reference/wspr_reference.py --negative-control "K1ABC FN42 37"

Everything in this file is bench/simulation material only.  ``K1ABC FN42 37``
must never be radiated (docs/spec.md section 15; plan section 0.1).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Sequence, Tuple

import numpy as np

# ---------------------------------------------------------------------------
# Frozen protocol constants (docs/spec.md)
# ---------------------------------------------------------------------------

# Source encoding, docs/spec.md section 2.
CALLSIGN_BITS = 28
GRID_BITS = 15
POWER_BITS = 7
PAYLOAD_BITS = 50

# Forward error correction, docs/spec.md section 3.
TAIL_BITS = 31
FEC_INPUT_BITS = PAYLOAD_BITS + TAIL_BITS          # 81
POLY1 = 0xF2D05351
POLY2 = 0xE4613C47

# Interleaving + symbols, docs/spec.md sections 4-5.
CODED_BITS = 162
SYMBOL_COUNT = 162

# Modulation / timing defaults, docs/spec.md sections 6, 7, 9.
TONE_SPACING_HZ = 12000.0 / 8192.0                 # 1.46484375 Hz
SYMBOL_DURATION_S = 8192.0 / 12000.0               # 0.68266... s
TX_DURATION_S = SYMBOL_COUNT * SYMBOL_DURATION_S   # 110.592 s (exact)
TX_START_OFFSET_S = 1.0                            # docs/spec.md section 7
DEFAULT_RF_FREQUENCY_HZ = 10140200                 # docs/spec.md section 9
AUDIO_CENTER_HZ = 1500.0                           # docs/spec.md section 6

# Power field is 7 bits but WSPR only defines 0..60 dBm; the packing adds 64,
# so 0..60 keeps ``power + 64`` inside 7 bits (docs/spec.md section 2).
MIN_POWER_DBM = 0
MAX_POWER_DBM = 60

# Sync vector, docs/spec.md section 5 (source of truth lib/wsprd/WSPRcode.f90).
SYNC_VECTOR = np.array(
    [
        1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 1, 0,
        0, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1,
        0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1,
        1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1,
        0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 0, 0, 0, 1, 0,
        0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 0, 0, 1, 1,
        0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 1, 1,
        0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0,
        0, 0,
    ],
    dtype=np.uint8,
)

# Even-parity lookup table: PARTAB[b] = parity of the 8 bits of b.
# docs/spec.md section 3 (lib/wsprd/tab.c, lib/conv232.f90).
PARTAB = np.array([bin(b).count("1") & 1 for b in range(256)], dtype=np.uint8)


class WSPRError(ValueError):
    """Raised when a message is not a valid WSPR Type-1 message."""


# ---------------------------------------------------------------------------
# Source encoding (docs/spec.md section 2)
# ---------------------------------------------------------------------------


def _callsign_char_code(ch: str) -> int:
    """Return the WSPR callsign character code (docs/spec.md section 2).

    ``'0'..'9' -> 0..9``, ``' ' -> 36``, ``'A'..'Z' -> 10..35``.
    """
    if "0" <= ch <= "9":
        return ord(ch) - ord("0")
    if ch == " ":
        return 36
    if "A" <= ch <= "Z":
        return ord(ch) - (ord("A") - 10)
    raise WSPRError(f"invalid callsign character {ch!r}")


def _locator_char_code(ch: str) -> int:
    """Return the WSPR locator character code (docs/spec.md section 2).

    ``'0'..'9' -> 0..9``, ``' ' -> 36``, ``'A'..'R' -> 0..17``.
    """
    if "0" <= ch <= "9":
        return ord(ch) - ord("0")
    if ch == " ":
        return 36
    if "A" <= ch <= "R":
        return ord(ch) - ord("A")
    raise WSPRError(f"invalid locator character {ch!r}")


def align_callsign(callsign: str) -> str:
    """Pad/align a callsign to the canonical 6 characters (docs/spec.md section 2).

    If the 3rd character is a digit the callsign is used as-is; otherwise, if the
    2nd character is a digit, the callsign is shifted one place right and a
    leading space is padded.  Any other form cannot be encoded by the Type-1
    callsign field and is rejected with a clear error.
    """
    callsign = callsign.upper()
    if not 3 <= len(callsign) <= 6:
        raise WSPRError(
            f"callsign {callsign!r}: Type-1 callsigns must be 3..6 characters"
        )
    if not all(("A" <= c <= "Z") or ("0" <= c <= "9") for c in callsign):
        raise WSPRError(
            f"callsign {callsign!r}: only A-Z and 0-9 are allowed in Type-1"
        )

    call6 = [" "] * 6
    if callsign[2].isdigit():
        # digit in 3rd position: use as-is (e.g. AB1C, VK2ABC).
        for i, ch in enumerate(callsign):
            call6[i] = ch
    elif callsign[1].isdigit():
        # digit in 2nd position: shift right by one, pad a leading space
        # (e.g. K1ABC -> " K1ABC").  A 6-character callsign cannot shift.
        if len(callsign) > 5:
            raise WSPRError(
                f"callsign {callsign!r}: a 6-character callsign must have its "
                "digit in the 3rd position"
            )
        for i, ch in enumerate(callsign):
            call6[i + 1] = ch
    else:
        raise WSPRError(
            f"callsign {callsign!r}: Type-1 callsigns need a digit in the 2nd "
            "or 3rd position (e.g. K1ABC, AB1C, VK2ABC)"
        )
    # Positions 4..6 of the aligned callsign are the base-27 suffix: only A-Z
    # or padding space are valid there (docs/spec.md section 2).
    if not all(("A" <= c <= "Z") or c == " " for c in call6[3:6]):
        raise WSPRError(
            f"callsign {callsign!r}: characters after the callsign digit must "
            "be letters A-Z"
        )
    return "".join(call6)


def pack_callsign(callsign: str) -> int:
    """Pack a callsign into the 28-bit field ``n`` (docs/spec.md section 2)."""
    call6 = align_callsign(callsign)
    codes = [_callsign_char_code(ch) for ch in call6]
    n = codes[0]
    n = 36 * n + codes[1]
    n = 10 * n + codes[2]
    n = 27 * n + (codes[3] - 10)
    n = 27 * n + (codes[4] - 10)
    n = 27 * n + (codes[5] - 10)
    if not 0 <= n < (1 << CALLSIGN_BITS):
        raise WSPRError(
            f"callsign {callsign!r}: packed value {n} does not fit in "
            f"{CALLSIGN_BITS} bits"
        )
    return n


def pack_grid_power(grid: str, power: int) -> int:
    """Pack a 4-character locator + power into the 22-bit field ``m``.

    ``m = ((179 - 10*g0 - g2)*180 + 10*g1 + g3)*128 + power + 64`` with the
    locator character codes of docs/spec.md section 2.
    """
    grid = grid.upper()
    if len(grid) != 4:
        raise WSPRError(f"grid {grid!r}: a Type-1 grid is 4 characters (e.g. FN42)")
    if not ("A" <= grid[0] <= "R" and "A" <= grid[1] <= "R"):
        raise WSPRError(
            f"grid {grid!r}: the first two characters must be A-R (Maidenhead)"
        )
    if not (grid[2].isdigit() and grid[3].isdigit()):
        raise WSPRError(f"grid {grid!r}: the last two characters must be digits")
    if not MIN_POWER_DBM <= power <= MAX_POWER_DBM:
        raise WSPRError(
            f"power {power!r}: WSPR power must be {MIN_POWER_DBM}..{MAX_POWER_DBM} dBm"
        )

    g0 = _locator_char_code(grid[0])
    g1 = _locator_char_code(grid[1])
    g2 = _locator_char_code(grid[2])
    g3 = _locator_char_code(grid[3])
    m = ((179 - 10 * g0 - g2) * 180 + 10 * g1 + g3) * 128 + power + 64
    if not 0 <= m < (1 << (GRID_BITS + POWER_BITS)):
        raise WSPRError(f"grid/power packed value {m} does not fit in 22 bits")
    return m


def parse_message(message: str) -> Tuple[str, str, int]:
    """Split and validate a ``CALLSIGN GRID4 POWER`` Type-1 message.

    Only the standard Type-1 textual form is accepted.  Type 2 (``PREFIX/CALL``)
    and Type 3 (``<CALL> GRID6``) are rejected with a clear error rather than
    silently encoded as garbage.
    """
    if "/" in message:
        raise WSPRError(
            "message contains '/': Type-2 (prefix/suffix) messages are not "
            "supported by this Type-1 model"
        )
    if "<" in message or ">" in message:
        raise WSPRError(
            "message contains '<'/'>': Type-3 messages are not supported by "
            "this Type-1 model"
        )
    parts = message.split()
    if len(parts) != 3:
        raise WSPRError(
            f"message {message!r}: expected the Type-1 form "
            "'CALLSIGN GRID4 POWER_dBm'"
        )
    callsign, grid, power_str = parts
    try:
        power = int(power_str, 10)
    except ValueError:
        raise WSPRError(f"power {power_str!r} is not an integer dBm value")
    return callsign, grid, power


# ---------------------------------------------------------------------------
# Bit assembly (docs/spec.md section 2)
# ---------------------------------------------------------------------------


def pack_payload_bytes(n: int, m: int) -> List[int]:
    """Assemble the 11 data bytes: 7 payload bytes + 4 zero tail bytes.

    Exact bit assembly of docs/spec.md section 2 (50 payload bits, MSB-first).
    """
    data = [0] * 11
    data[0] = (n >> 20) & 0xFF
    data[1] = (n >> 12) & 0xFF
    data[2] = (n >> 4) & 0xFF
    data[3] = ((n & 0x0F) << 4) + ((m >> 18) & 0x0F)
    data[4] = (m >> 10) & 0xFF
    data[5] = (m >> 2) & 0xFF
    data[6] = (m & 0x03) << 6
    # data[7..10] remain zero (31 tail bits + 7 padding zero bits).
    return data


def bytes_to_bits(data: Sequence[int]) -> np.ndarray:
    """Expand bytes MSB-first to a bit array (docs/spec.md section 3)."""
    return np.array(
        [(byte >> i) & 1 for byte in data for i in range(7, -1, -1)],
        dtype=np.uint8,
    )


def payload_bits(data: Sequence[int]) -> np.ndarray:
    """Return the 50 payload bits (first 50 of the 56 packed payload bits)."""
    return bytes_to_bits(data[:7])[:PAYLOAD_BITS]


def fec_input_bits(data: Sequence[int]) -> np.ndarray:
    """Return the 81 FEC input bits = 50 payload + 31 zero tail (section 3)."""
    tail = np.zeros(TAIL_BITS, dtype=np.uint8)
    return np.concatenate([payload_bits(data), tail])


# ---------------------------------------------------------------------------
# Convolutional FEC (docs/spec.md section 3)
# ---------------------------------------------------------------------------


def _parity32(value: int) -> int:
    """Even parity of a 32-bit word via the two-XOR-shift fold of section 3."""
    tmp = value & 0xFFFFFFFF
    tmp ^= tmp >> 16
    return int(PARTAB[(tmp ^ (tmp >> 8)) & 0xFF])


def conv_encode(bits: Sequence[int]) -> np.ndarray:
    """Rate-1/2, K=32 Layland-Lushbaugh convolutional encoder (section 3).

    Newest input bit enters the LSB of a 32-bit shift register; for each input
    bit the POLY1 parity is emitted first, then the POLY2 parity.  81 input
    bits therefore produce exactly 162 coded bits.
    """
    state = 0
    out: List[int] = []
    for bit in bits:
        state = ((state << 1) | (int(bit) & 1)) & 0xFFFFFFFF
        out.append(_parity32(state & POLY1))
        out.append(_parity32(state & POLY2))
    coded = np.array(out, dtype=np.uint8)
    if len(coded) != CODED_BITS:
        raise AssertionError(f"expected {CODED_BITS} coded bits, got {len(coded)}")
    return coded


# ---------------------------------------------------------------------------
# Interleaving (docs/spec.md section 4)
# ---------------------------------------------------------------------------


def _bit_reverse8(value: int) -> int:
    """Reverse the 8 bits of ``value`` (docs/spec.md section 4)."""
    result = 0
    for _ in range(8):
        result = (result << 1) | (value & 1)
        value >>= 1
    return result


def _build_interleave_table() -> np.ndarray:
    """162-entry permutation j0: bit-reversed 8-bit indices, kept in i order."""
    table = [n for i in range(256) if (n := _bit_reverse8(i)) <= CODED_BITS - 1]
    table_arr = np.array(table, dtype=np.int64)
    if len(table_arr) != CODED_BITS or sorted(table) != list(range(CODED_BITS)):
        raise AssertionError("interleaver index table is not a permutation of 0..161")
    return table_arr


INTERLEAVE_TABLE = _build_interleave_table()


def interleave(bits: Sequence[int]) -> np.ndarray:
    """Encoder interleaving: ``out[j0[p]] = bits[p]`` (docs/spec.md section 4)."""
    src = np.asarray(bits, dtype=np.uint8)
    if len(src) != CODED_BITS:
        raise ValueError(f"interleave expects {CODED_BITS} bits")
    out = np.zeros(CODED_BITS, dtype=np.uint8)
    out[INTERLEAVE_TABLE] = src
    return out


def deinterleave(bits: Sequence[int]) -> np.ndarray:
    """Decoder de-interleaving: ``out[i] = bits[j0[i]]`` (docs/spec.md section 4)."""
    src = np.asarray(bits, dtype=np.uint8)
    if len(src) != CODED_BITS:
        raise ValueError(f"deinterleave expects {CODED_BITS} bits")
    return src[INTERLEAVE_TABLE]


# ---------------------------------------------------------------------------
# Sync + symbols + tones (docs/spec.md sections 5, 6)
# ---------------------------------------------------------------------------


def add_sync(data_bits: Sequence[int]) -> np.ndarray:
    """Channel symbols: ``symbol = 2*data_bit + sync_bit`` (docs/spec.md section 5)."""
    data = np.asarray(data_bits, dtype=np.uint8)
    if len(data) != SYMBOL_COUNT:
        raise ValueError(f"add_sync expects {SYMBOL_COUNT} data bits")
    return 2 * data + SYNC_VECTOR


def tone_frequencies(rf_frequency_hz: float = DEFAULT_RF_FREQUENCY_HZ) -> np.ndarray:
    """Four carrier offsets ``(tone - 1.5) * spacing`` about the RF carrier.

    docs/spec.md section 6 (lib/wsprd/wsprsimf.f90:67-73).
    """
    return rf_frequency_hz + (np.arange(4) - 1.5) * TONE_SPACING_HZ


def symbol_frequency(tone: int, rf_frequency_hz: float = DEFAULT_RF_FREQUENCY_HZ) -> float:
    """Convenience: absolute frequency of one channel symbol (tone 0..3)."""
    return float(rf_frequency_hz + (tone - 1.5) * TONE_SPACING_HZ)


# ---------------------------------------------------------------------------
# The full chain
# ---------------------------------------------------------------------------


@dataclass
class Encoded:
    """All intermediate and final products of the WSPR Type-1 encode chain."""

    message: str
    callsign_aligned: str
    n: int
    m: int
    payload_bytes: List[int]
    payload_bits: np.ndarray
    fec_input_bits: np.ndarray
    coded_bits: np.ndarray
    interleaved_bits: np.ndarray
    sync_bits: np.ndarray
    symbols: np.ndarray
    tones: np.ndarray = field(repr=False)


def encode_message(
    message: str, rf_frequency_hz: float = DEFAULT_RF_FREQUENCY_HZ
) -> Encoded:
    """Encode a Type-1 message end to end (plan section 20 chain)."""
    callsign, grid, power = parse_message(message)
    n = pack_callsign(callsign)
    m = pack_grid_power(grid, power)
    data = pack_payload_bytes(n, m)
    payload = payload_bits(data)
    fec_in = fec_input_bits(data)
    coded = conv_encode(fec_in)
    inter = interleave(coded)
    symbols = add_sync(inter)
    tones = tone_frequencies(rf_frequency_hz)
    return Encoded(
        message=message,
        callsign_aligned=align_callsign(callsign),
        n=n,
        m=m,
        payload_bytes=data,
        payload_bits=payload,
        fec_input_bits=fec_in,
        coded_bits=coded,
        interleaved_bits=inter,
        sync_bits=SYNC_VECTOR.copy(),
        symbols=symbols,
        tones=tones,
    )


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------


def bits_to_str(bits: Sequence[int], group: int = 30) -> List[str]:
    """Format a bit array as lines of ``group`` digits (wsprcode-like)."""
    text = "".join(str(int(b)) for b in bits)
    return [text[i : i + group] for i in range(0, len(text), group)]


def hex_bytes(data: Sequence[int]) -> str:
    return " ".join(f"{b:02X}" for b in data)


def format_hz(value: float) -> str:
    """Format a frequency in Hz without trailing zeros or scientific notation."""
    return f"{value:.9f}".rstrip("0").rstrip(".")


def format_report(enc: Encoded, rf_frequency_hz: float = DEFAULT_RF_FREQUENCY_HZ) -> str:
    """Human-readable dump of every stage of the chain."""
    lines: List[str] = []
    lines.append(f"Message: {enc.message}")
    lines.append(f"  callsign member : {enc.callsign_aligned!r}")
    lines.append(f"  n (28-bit)      : {enc.n} (0x{enc.n:08X})")
    lines.append(f"  m (22-bit)      : {enc.m} (0x{enc.m:06X})")
    lines.append("")
    lines.append(f"PAYLOAD BYTES ({7} payload + {4} tail = 11 bytes):")
    lines.append(f"  hex:  {hex_bytes(enc.payload_bytes)}")
    lines.append("")
    lines.append(f"PAYLOAD BITS ({PAYLOAD_BITS}):")
    lines.append(f"  bits: {' '.join(bits_to_str(enc.payload_bits, 8))}")
    lines.append("")
    lines.append(
        f"FEC INPUT BITS ({FEC_INPUT_BITS} = {PAYLOAD_BITS} payload + "
        f"{TAIL_BITS} tail zeros):"
    )
    for line in bits_to_str(enc.fec_input_bits):
        lines.append(f"  {line}")
    lines.append("")
    lines.append(f"CODED BITS ({CODED_BITS}):")
    for line in bits_to_str(enc.coded_bits):
        lines.append(f"  {line}")
    lines.append("")
    lines.append(f"INTERLEAVED BITS ({CODED_BITS}):")
    for line in bits_to_str(enc.interleaved_bits):
        lines.append(f"  {line}")
    lines.append("")
    lines.append(f"SYNC BITS ({SYMBOL_COUNT}):")
    for line in bits_to_str(enc.sync_bits):
        lines.append(f"  {line}")
    lines.append("")
    lines.append(f"CHANNEL SYMBOLS ({SYMBOL_COUNT}, 0..3 = 2*data_bit + sync_bit):")
    for line in bits_to_str(enc.symbols):
        lines.append(f"  {line}")
    lines.append("")
    lines.append(f"TONES ({len(enc.tones)}) at RF = {format_hz(rf_frequency_hz)} Hz:")
    for tone, freq in enumerate(enc.tones):
        lines.append(f"  tone {tone}: {format_hz(float(freq))} Hz")
    lines.append(f"  (tone spacing {TONE_SPACING_HZ:.9f} Hz, "
                 f"symbol duration {SYMBOL_DURATION_S:.9f} s)")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Golden known-answer vectors, cross-checked bit-for-bit with
# /usr/bin/wsprcode (Debian wsjtx 2.7.0+repack-1, upstream WSJT-X 2.7.0).
# The channel-symbol strings below are the wsprcode output verbatim.
# ---------------------------------------------------------------------------

_KAT: Dict[str, Dict[str, str]] = {
    "K1ABC FN42 37": {
        "payload_hex": "F7 0C 23 8B 0D 19 40",
        "symbols": (
            "330020001020131222100323133220200032012322002232110233210221321222"
            "033030301210212032132003323032203020201023021112330231212221332000"
            "010320132222202332323320031222"
        ),
    },
    "K1ABC FN42 27": {
        "payload_hex": "F7 0C 23 8B 0D 16 C0",
        "symbols": (
            "330220001220111222120123113220200030032120002230130033210223321222"
            "013230321010232230132203323230203022221021021112310233212223332000"
            "030122132020222130303122031022"
        ),
    },
    "VK2ABC QF56 37": {
        "payload_hex": "D5 47 30 31 42 19 40",
        "symbols": (
            "312200001002111220302103313020200212010320220212310211212023103222"
            "211010121230212232312021323212003002203001023110332231210003332220"
            "212322332022002130323120213202"
        ),
    },
}


def _symbols_to_str(symbols: Sequence[int]) -> str:
    return "".join(str(int(s)) for s in symbols)


def compare_symbols(got: Sequence[int], ref: Sequence[int]) -> List[int]:
    """Return the indices where two symbol sequences differ."""
    got_a = np.asarray(got)
    ref_a = np.asarray(ref)
    if got_a.shape != ref_a.shape:
        raise ValueError("symbol sequences have different lengths")
    return [i for i in range(len(got_a)) if got_a[i] != ref_a[i]]


# ---------------------------------------------------------------------------
# Reference-decoder cross-check (/usr/bin/wsprcode)
# ---------------------------------------------------------------------------


def run_wsprcode(message: str, wsprcode_path: str) -> Tuple[List[int], List[int], List[int]]:
    """Run the pinned reference encoder and parse its symbol output.

    Returns ``(data_symbols, sync_symbols, channel_symbols)`` as lists of ints.
    """
    proc = subprocess.run(
        [wsprcode_path, message],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise WSPRError(
            f"{wsprcode_path} failed for {message!r}: {proc.stderr.strip()}"
        )
    out = proc.stdout

    def _section(name: str) -> List[int]:
        start = out.index(name)
        end = out.find("\n\n", start)
        if end == -1:
            end = len(out)
        return [int(tok) for tok in re.findall(r"[0-9]+", out[start:end])]

    return _section("Data symbols:"), _section("Sync symbols:"), _section("Channel symbols:")


def cross_check_wsprcode(enc: Encoded, wsprcode_path: str) -> int:
    """Compare our channel symbols against wsprcode; return number of diffs."""
    _, _, ref = run_wsprcode(enc.message, wsprcode_path)
    if len(ref) != SYMBOL_COUNT:
        raise WSPRError(f"wsprcode returned {len(ref)} channel symbols, expected 162")
    return len(compare_symbols(enc.symbols, ref))


# ---------------------------------------------------------------------------
# Self-test and negative control (plan section 20)
# ---------------------------------------------------------------------------


def self_test(wsprcode_path: str | None = None) -> int:
    """Re-derive the chain and assert internal + golden consistency.

    Returns 0 on success, 1 on any failure.
    """
    failures: List[str] = []

    def check(condition: bool, label: str) -> None:
        if condition:
            print(f"  PASS  {label}")
        else:
            failures.append(label)
            print(f"  FAIL  {label}")

    print("self-test: structural checks")
    check(len(SYNC_VECTOR) == SYMBOL_COUNT, "sync vector has 162 bits")
    check(int(SYNC_VECTOR.sum()) == 63, "sync vector popcount is 63")
    check(
        sorted(INTERLEAVE_TABLE.tolist()) == list(range(CODED_BITS)),
        "interleave index table is a permutation of 0..161",
    )

    rng = np.random.default_rng(0x575052)  # deterministic "WSPR" seed
    for trial in range(3):
        bits = rng.integers(0, 2, size=CODED_BITS, dtype=np.uint8)
        roundtrip = deinterleave(interleave(bits))
        check(
            np.array_equal(roundtrip, bits),
            f"deinterleave(interleave(x)) == x (trial {trial})",
        )

    print("self-test: symbols re-derive from data + sync")
    for msg in _KAT:
        enc = encode_message(msg)
        check(
            np.array_equal(enc.symbols, 2 * enc.interleaved_bits + SYNC_VECTOR),
            f"{msg!r}: symbols == 2*interleaved + sync",
        )

    print("self-test: golden known-answer vectors (vs wsprcode 2.7.0)")
    for msg, kat in _KAT.items():
        enc = encode_message(msg)
        payload_ok = hex_bytes(enc.payload_bytes[:7]) == kat["payload_hex"]
        check(payload_ok, f"{msg!r}: 50-bit payload == {kat['payload_hex']}")
        diffs = compare_symbols(enc.symbols, [int(c) for c in kat["symbols"]])
        check(len(diffs) == 0, f"{msg!r}: 162 channel symbols match golden (0/162)")

    if wsprcode_path:
        print(f"self-test: live cross-check vs {wsprcode_path}")
        for msg in _KAT:
            enc = encode_message(msg)
            try:
                diff_count = cross_check_wsprcode(enc, wsprcode_path)
            except Exception as exc:  # pragma: no cover - environment dependent
                check(False, f"{msg!r}: wsprcode cross-check ({exc})")
                continue
            check(diff_count == 0, f"{msg!r}: wsprcode cross-check = {diff_count}/162")

    print()
    if failures:
        print(f"self-test: FAILED ({len(failures)} check(s))")
        for label in failures:
            print(f"  - {label}")
        return 1
    print("self-test: ALL CHECKS PASSED")
    return 0


def negative_control(message: str, wsprcode_path: str | None) -> int:
    """Deliberately perturb one symbol and prove the comparison can fail.

    Flips channel symbol index 80 (mod 4) and reports the mismatch against the
    golden vector and, when available, against wsprcode.  Returns 0 when
    exactly one difference is detected, 1 otherwise.
    """
    if message not in _KAT:
        raise WSPRError(
            f"negative control needs a golden vector; known: {sorted(_KAT)}"
        )
    enc = encode_message(message)
    perturbed = enc.symbols.copy()
    index = 80
    perturbed[index] = (int(perturbed[index]) + 1) % 4
    golden = [int(c) for c in _KAT[message]["symbols"]]

    diffs_golden = compare_symbols(perturbed, golden)
    print(f"negative control on {message!r}")
    print(f"  perturbed symbol index {index}: "
          f"{int(enc.symbols[index])} -> {int(perturbed[index])}")
    print(f"  vs golden vector   : {len(diffs_golden)}/162 differences "
          f"at indices {diffs_golden}")
    rc = 0
    if len(diffs_golden) != 1:
        rc = 1
    if wsprcode_path:
        _, _, ref = run_wsprcode(message, wsprcode_path)
        diffs_ref = compare_symbols(perturbed, ref)
        print(f"  vs wsprcode 2.7.0  : {len(diffs_ref)}/162 differences "
              f"at indices {diffs_ref}")
        if len(diffs_ref) != 1:
            rc = 1
    return rc


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _vector_tone_lines(enc: Encoded) -> List[str]:
    lines = [f"TONES ({len(enc.tones)} at RF = {format_hz(float(DEFAULT_RF_FREQUENCY_HZ))} Hz)"]
    for tone, freq in enumerate(enc.tones):
        lines.append(f"tone {tone}: {format_hz(float(freq))} Hz")
    return lines


def format_vector(enc: Encoded) -> str:
    """Emit the frozen-vector body (provenance header added when freezing)."""
    lines: List[str] = []
    lines.append(f"# message: {enc.message}")
    lines.append(f"# n = {enc.n} (0x{enc.n:08X})   m = {enc.m} (0x{enc.m:06X})")
    lines.append("")
    lines.append(f"PAYLOAD BITS ({PAYLOAD_BITS})")
    lines.append(f"hex:  {hex_bytes(enc.payload_bytes[:7])}")
    lines.append(f"bits: {' '.join(bits_to_str(enc.payload_bits, 8))}")
    lines.append("")
    lines.append(f"FEC INPUT BITS ({FEC_INPUT_BITS})")
    for line in bits_to_str(enc.fec_input_bits):
        lines.append(line)
    lines.append("")
    lines.append(f"CODED BITS ({CODED_BITS})")
    for line in bits_to_str(enc.coded_bits):
        lines.append(line)
    lines.append("")
    lines.append(f"INTERLEAVED ({CODED_BITS})")
    for line in bits_to_str(enc.interleaved_bits):
        lines.append(line)
    lines.append("")
    lines.append(f"SYNC ({SYMBOL_COUNT})")
    for line in bits_to_str(enc.sync_bits):
        lines.append(line)
    lines.append("")
    lines.append(f"SYMBOLS ({SYMBOL_COUNT})")
    for line in bits_to_str(enc.symbols):
        lines.append(line)
    lines.append("")
    lines.extend(_vector_tone_lines(enc))
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Independent WSPR Type-1 encoder reference model (Agent E, Phase 16). "
            "Bench/simulation only; never radiate K1ABC FN42 37."
        )
    )
    parser.add_argument(
        "message",
        nargs="?",
        help="Type-1 message, e.g. 'K1ABC FN42 37'",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run internal + golden-vector consistency checks and exit",
    )
    parser.add_argument(
        "--negative-control",
        metavar="MESSAGE",
        default=None,
        help="flip one symbol and show that the comparison detects it",
    )
    parser.add_argument(
        "--compare-wsprcode",
        action="store_true",
        help="cross-check the channel symbols against /usr/bin/wsprcode",
    )
    parser.add_argument(
        "--wsprcode",
        default="/usr/bin/wsprcode",
        help="path to the reference encoder (default: /usr/bin/wsprcode)",
    )
    parser.add_argument(
        "--vector",
        action="store_true",
        help="emit the frozen-vector body instead of the full report",
    )
    parser.add_argument(
        "--rf-frequency",
        type=float,
        default=DEFAULT_RF_FREQUENCY_HZ,
        help=f"RF carrier in Hz for the tone table (default: {DEFAULT_RF_FREQUENCY_HZ})",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    wsprcode_path = args.wsprcode if shutil.which(args.wsprcode) or _is_file(args.wsprcode) else None

    if args.self_test:
        return self_test(wsprcode_path)

    if args.negative_control is not None:
        return negative_control(args.negative_control, wsprcode_path)

    if args.message is None:
        parser.error("a MESSAGE is required (or use --self-test / --negative-control)")

    try:
        enc = encode_message(args.message, rf_frequency_hz=args.rf_frequency)
    except WSPRError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.vector:
        print(format_vector(enc))
        return 0

    print(format_report(enc, rf_frequency_hz=args.rf_frequency))
    if args.compare_wsprcode:
        if wsprcode_path is None:
            print(f"\nerror: reference encoder not found at {args.wsprcode}",
                  file=sys.stderr)
            return 2
        diffs = cross_check_wsprcode(enc, wsprcode_path)
        status = "OK" if diffs == 0 else "MISMATCH"
        print(f"\nwsprcode cross-check: {diffs}/162 symbol differences ({status})")
        return 0 if diffs == 0 else 1
    return 0


def _is_file(path: str) -> bool:
    return os.path.isfile(path)


if __name__ == "__main__":
    sys.exit(main())
