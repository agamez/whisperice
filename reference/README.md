# reference/ — Independent WSPR reference material

This directory will hold the independent Python WSPR reference model
(`wspr_reference.py`, Agent E / Phase 16) and the frozen test vectors
(`test_vectors/`, e.g. `k1abc_fn42_37.txt` for the conventional documentation
example `K1ABC FN42 37` — bench/simulation use only, never radiated).

## Reference decoder available on this host

- **`wsprd`** (command-line WSPR decoder) — installed system-wide at
  `/usr/bin/wsprd`, from the Debian package **wsjtx 2.7.0+repack-1**
  (upstream **WSJT-X 2.7.0**).
- Source for pinning/citation: `apt-get source wsjtx` (Debian trixie).

All protocol constants frozen in `docs/protocol.md` must be resolved against
this WSJT-X version and cite it explicitly (plan §0.1, §36 ref 9, §37).

## Reference model runtime

- Python 3.13.5 with numpy 2.2.4 (OS package `python3-numpy`) — sufficient for
  the reference-model script; no additional pip packages were installed.

Both files in this directory (`wspr_reference.py`, `test_vectors/`) are
currently **empty placeholders** created during environment setup.
