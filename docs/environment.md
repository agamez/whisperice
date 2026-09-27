# Development Environment — wspr-icebreaker

> Prepared by the Setup Agent on **2026-09-27**. This file documents exactly what is installed
> on this host, at what version, how it was installed, and the verification command used for
> each item, so the environment can be reproduced on another machine.
>
> **Overall setup status: PASS** — every required tool is installed and verified.
> One explicit caveat: **no iCEBreaker hardware was attached during setup**, so on-target
> programming (`iceprog`) could not be exercised. See §4 for details.

---

## 1. Host

| Item | Value |
|---|---|
| OS | Debian GNU/Linux 13 (trixie), amd64 |
| Kernel | 6.12.107+deb13-amd64 |
| Package manager | `apt` (Debian) |
| User privileges | uid 1000, member of `plugdev`; passwordless-capable `sudo` used for installs |

All tools were installed from the **official Debian 13 (trixie) repositories** as OS packages.
No tool required a source build, so no source pinning is needed — each package version is
pinned by the Debian archive itself. On another Debian 13 machine, the exact same versions are
obtained with:

```sh
sudo apt-get install -y yosys nextpnr-ice40 fpga-icestorm ghdl wsjtx python3-numpy git make
```

---

## 2. Installed tools — summary table

| # | Tool | Version | Install method | Check command | Status |
|---|------|---------|----------------|---------------|--------|
| 1 | Yosys (synthesis) | 0.52-2 (binary reports `0.52`, git sha1 `fee39a3284c90249e1d9684cf6944ffbbcbb8f90`) | apt (`yosys`) | `yosys -V` | PASS |
| 2 | nextpnr-ice40 (P&R) | 0.7-1+b2 | apt (`nextpnr-ice40`) | `nextpnr-ice40 --version` | PASS |
| 3 | Project IceStorm (`icepack`/`iceunpack`/`iceprog`/`icetime`/`icebram`/`icepll`/`icemulti` + icebox python tools) | 0~20250207git7fbf8c0+dfsg1-1 | apt (`fpga-icestorm`) | `dpkg -s fpga-icestorm`; `icepack` (prints usage) | PASS |
| 4 | GHDL (VHDL simulator) | 5.0.1+dfsg-1+b1 ("Dunoon edition", mcode JIT, built with GNAT 14.2.0) | apt (`ghdl`) | `ghdl --version` | PASS |
| 5 | GHDL `--std=93` support (VHDL-93) | verified by analyze/elaborate/run smoke test | — | see §3.2 | PASS |
| 6 | iceprog (programming) | same package as #3 (fpga-icestorm) | apt | `iceprog` (prints usage) | PASS (binary; hardware not attached — see §4) |
| 7 | Python 3 | 3.13.5 | preinstalled on host | `python3 --version` | PASS |
| 8 | pip | 25.1.1 | preinstalled on host | `pip3 --version` | PASS |
| 9 | numpy | 2.2.4 (`python3-numpy` apt package) | apt (`python3-numpy`) | `python3 -c "import numpy; print(numpy.__version__)"` | PASS |
| 10 | git | 2.47.3 | apt (preinstalled) | `git --version` | PASS |
| 11 | WSJT-X incl. `wsprd` (WSPR reference decoder) | 2.7.0+repack-1 (upstream 2.7.0) | apt (`wsjtx`) | `wsprd` (prints usage); `dpkg -s wsjtx` | PASS |
| 12 | GNU Make | 4.4.1 | apt (preinstalled) | `make --version` | PASS |
| 13 | gcc (host compiler, needed by GHDL mcode runtime) | 14.2.0-19 | apt (preinstalled) | `gcc --version` | PASS |
| 14 | libftdi1 (USB/FTDI runtime for iceprog) | 1.5-10 | apt (dependency of fpga-icestorm) | `dpkg -s libftdi1-2` | PASS |

---

## 3. Verification details

### 3.1 End-to-end UP5K toolchain smoke test — PASS

A throwaway counter design (not project RTL; left in `/tmp/opencode/flow_smoke/`) was pushed
through the complete flow targeting the actual iCE40UP5K / SG48 package:

```sh
yosys -q -p "read_verilog blinky.v; synth_ice40 -top blinky -json blinky.json"
nextpnr-ice40 --up5k --package sg48 --pcf smoke.pcf --json blinky.json --asc blinky.asc --freq 12
#   → "Program finished normally", max freq 66.27 MHz (PASS at 12.00 MHz)
icepack blinky.asc blinky.bin          # → valid 104,090-byte bitstream
icetime -d up5k blinky.asc             # → reads UP5K chipdb, timing estimate 61.71 MHz
```

Result: **full Yosys → nextpnr-ice40 → icepack → icetime chain works for the UP5K target.**

Notes for later agents (from this smoke test):

- nextpnr-ice40 0.7 takes **`--json`** input (BLIF input support was removed) — have Yosys emit
  `-json`, not `-blif`.
- The UP5K chip database is at `/usr/share/nextpnr/ice40/chipdb-5k.bin` (shipped by the
  `nextpnr-ice40` package); `icetime -d up5k` works out of the box.

### 3.2 GHDL `--std=93` smoke test — PASS

A minimal entity was analyzed, elaborated and run **strictly in VHDL-93 mode**:

```sh
ghdl -a --std=93 smoke.vhd
ghdl -e --std=93 smoke
ghdl -r --std=93 smoke --assert-level=error
```

Result: all three stages completed without error. GHDL 5.0.1 does support `--std=93`
(accepted standards include `93`, `93c`, `00`, `02`, `08`, `19`). **The project must use
`--std=93` explicitly on every `ghdl -a/-e/-r` invocation** — do not rely on the default
standard, which is newer than 93.

### 3.3 WSJT-X / wsprd reference decoder

- Installed: Debian package **`wsjtx` 2.7.0+repack-1** (upstream version **2.7.0**).
- The command-line decoder binary is at **`/usr/bin/wsprd`** and runs standalone
  (`wsprd <file.wav|file.c2>`), so bench decode tests do not need the GUI.
- **Citation for later phases:** all protocol timing constants (especially the 1 s vs. 2 s
  TX-start offset flagged in the plan §0.1/§37) must be resolved against **WSJT-X 2.7.0** and
  the exact source must be re-derivable via `apt-get source wsjtx` (package `wsjtx`,
  version `2.7.0+repack-1`, Debian trixie). Record the resolved value in `docs/protocol.md`
  citing this version.
- Rationale for the choice: installing the OS package is far more practical on this host than
  building `wsprd` from the WSJT-X source tree (the full source build pulls in Qt5, Fortran and
  a large dependency stack), and the Debian package provides the identical `wsprd` binary.
- The GUI (`wsjtx`) is also installed for interactive verification if wanted.

---

## 4. iCEBreaker hardware / USB programming

**Status: hardware NOT attached during setup — this item could NOT be verified on real
hardware. It is not a tool failure.**

Evidence:

```sh
$ lsusb | grep -i 0403
NO FTDI/FT2232H device found in lsusb
```

Everything on the host side is prepared for the board:

- `iceprog` (fpga-icestorm) is installed and functional.
- USB access rule installed by the package at `/lib/udev/rules.d/40-fpga-icestorm.rules`:
  ```
  ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0660", GROUP="plugdev", TAG+="uaccess"
  ```
  This matches the iCEBreaker's FT2232H bridge (VID:PID `0403:6010`).
- The current user is a member of `plugdev`, so no further udev configuration is expected.

**When the board is plugged in**, verify with:

```sh
lsusb | grep -i '0403:6010'   # device present
iceprog -t                    # cable test / device probe (no bitstream written)
```

If `iceprog -t` still fails after the board is attached, check the cable is the "USB directly
to the iCEBreaker" port and re-run `sudo udevadm control --reload-rules && sudo udevadm trigger`.

---

## 5. Repository skeleton created

Created exactly as specified in the plan §27 "Recommended Repository Structure". All
`.vhd`, `.py`, `.pcf` and protocol `.md` files are **empty placeholders** — their content is
the responsibility of the later phase agents:

```text
./
├── README.md                  ← written by Setup Agent (environment summary)
├── LICENSE                    ← written by Setup Agent (MIT, placeholder — may be changed)
├── Makefile                   ← stub by Setup Agent; real build flow = Phase 1 / Agent F
├── constraints/
│   └── icebreaker.pcf         ← EMPTY placeholder (Agent A must fill from official PCF)
├── src/
│   ├── top.vhd                ← EMPTY placeholders (RTL agents)
│   ├── clock/ gps/ timing/ nco/ wspr/   (all planned .vhd files created empty)
├── sim/                       ← all 8 planned testbench files created empty
├── reference/
│   ├── wspr_reference.py      ← EMPTY placeholder (Agent E)
│   ├── test_vectors/k1abc_fn42_37.txt ← EMPTY placeholder (Agent C/E)
│   └── README.md              ← written by Setup Agent (reference tooling notes)
├── tools/
│   ├── calculate_nco.py       ← EMPTY placeholders (Agent D / Phase 5)
│   └── inspect_wspr.py
└── docs/
    ├── architecture.md protocol.md gps.md rf.md verification.md lab.md ← EMPTY placeholders
    └── environment.md         ← this file (Setup Agent deliverable)
```

Note: the pre-existing `doc/` directory (orchestrator plan, setup briefs) is a different,
pre-existing directory and was left untouched; the plan-specified `docs/` directory now exists
alongside it.

---

## 6. Reproducing this environment elsewhere

On a Debian 13 (trixie) machine:

```sh
sudo apt-get update
sudo apt-get install -y yosys nextpnr-ice40 fpga-icestorm ghdl wsjtx python3-numpy git make
# optional, for non-root USB access to the board (rule ships with fpga-icestorm; ensure membership):
sudo usermod -aG plugdev "$USER"   # re-login afterwards
```

Version drift: Debian 13 is a stable release, so these exact package versions remain available
from the archive. For a different distro, pin these versions and rebuild from source:

| Tool | Pinned version | Upstream |
|---|---|---|
| Yosys | 0.52 | https://github.com/YosysHQ/yosys |
| nextpnr (ice40) | 0.7 | https://github.com/YosysHQ/nextpnr |
| Project IceStorm | 2025-02-07 snapshot (`7fbf8c0`) | https://clifford.at/icestorm/ |
| GHDL | 5.0.1 | https://ghdl.github.io/ghdl/ |
| WSJT-X (wsprd) | 2.7.0 | https://sourceforge.net/p/wsjt/wsjtx/ |
| numpy | 2.2.4 | https://numpy.org/ |
