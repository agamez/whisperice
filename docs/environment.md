# Development Environment — wspr-icebreaker

> **Revision 2 — 2026-09-27.** The FPGA/VHDL toolchain was migrated from Debian apt packages
> to **oss-cad-suite 2026-09-27** (pinned release) because Debian's Yosys has no GHDL plugin
> and cannot synthesize VHDL. See §1.1 for what changed. This file documents exactly what is
> installed, at what version, how it was installed, and the verification command used for each
> item, so the environment can be reproduced on another machine.
>
> **Overall setup status: PASS** — every required tool is installed and verified, including a
> full **VHDL-93 → UP5K bitstream** end-to-end test. One explicit caveat: **no iCEBreaker
> hardware was attached during setup**, so on-target programming (`iceprog`) could not be
> exercised. See §4.

---

## 1. Host

| Item | Value |
|---|---|
| OS | Debian GNU/Linux 13 (trixie), amd64 |
| Kernel | 6.12.107+deb13-amd64 |
| Package manager | `apt` (Debian) for OS/reference packages; oss-cad-suite release tarball for the FPGA/VHDL toolchain |
| User privileges | uid 1000, member of `plugdev`; `sudo` used for installs |

## 1.1 Revision history

| Rev | Change |
|---|---|
| 1 | Initial setup from Debian 13 apt (yosys 0.52-2, nextpnr-ice40 0.7-1+b2, fpga-icestorm, ghdl 5.0.1). Verified with a Verilog smoke test. |
| 2 | Debian `yosys`, `nextpnr-ice40`, `fpga-icestorm`, `ghdl` **removed** (Debian Yosys lacks the GHDL plugin → no VHDL synthesis). Replaced by **oss-cad-suite 2026-09-27** at `/opt/oss-cad-suite`. Full **VHDL-93 → UP5K bitstream** chain re-verified. `wsjtx` (wsprd), `python3-numpy`, `git` unchanged. |

---

## 2. Installed tools — summary table

| # | Tool | Version | Source / install method | Check command | Status |
|---|------|---------|------------------------|---------------|--------|
| 1 | Yosys (synthesis) | 0.69+154 (git sha1 `30d62572e`) | oss-cad-suite 2026-09-27 | `yosys -V` | PASS |
| 2 | GHDL + yosys plugin (`ghdl.so`) | 7.0.0-dev (6.0.0.r515.g6ea214092, Dunoon, GNAT 14.3.0, LLVM backend) | oss-cad-suite | `ghdl --version`; `yosys -m ghdl -p "ghdl --version"` | PASS |
| 3 | nextpnr-ice40 (P&R) | 0.11.1-34-gc4fbb55a | oss-cad-suite | `nextpnr-ice40 --version` | PASS |
| 4 | Project IceStorm (`icepack`/`iceunpack`/`iceprog`/`icetime`/`icebram`/`icepll`/`icemulti`) | bundled (20260927 build) | oss-cad-suite | `icepack` usage; `icetime -d up5k <asc>` | PASS |
| 5 | GHDL `--std=93` simulation | verified by analyze/elaborate/run smoke test | — | see §3.2 | PASS |
| 6 | VHDL-93 synthesis (`yosys -m ghdl` → `synth_ice40`) | verified end-to-end to UP5K bitstream | — | see §3.1 | PASS |
| 7 | iceprog (programming) | same as #4 | oss-cad-suite | `iceprog` (prints usage) | PASS (binary; hardware not attached — see §4) |
| 8 | Python 3 | 3.13.5 | preinstalled on host | `python3 --version` | PASS |
| 9 | pip | 25.1.1 | preinstalled on host | `pip3 --version` | PASS |
| 10 | numpy | 2.2.4 (Debian `python3-numpy`) | apt | `python3 -c "import numpy; print(numpy.__version__)"` | PASS |
| 11 | git | 2.47.3 | apt (preinstalled) | `git --version` | PASS |
| 12 | WSJT-X incl. `wsprd` (WSPR reference decoder) | **2.7.0+repack-1** (upstream **2.7.0**) | apt (`wsjtx`) | `wsprd` (prints usage) | PASS |
| 13 | GNU Make | 4.4.1 | apt (preinstalled) | `make --version` | PASS |
| 14 | gcc (host compiler) | 14.2.0-19 | apt (preinstalled) | `gcc --version` | PASS |
| 15 | libftdi1 (USB/FTDI runtime for iceprog) | 1.5-10 | apt | `dpkg -s libftdi1-2` | PASS |

---

## 3. Verification details

### 3.1 End-to-end VHDL-93 → UP5K bitstream smoke test — PASS

A throwaway VHDL-93 counter (not project RTL; left in `/tmp/opencode/vhdl_flow/`) was pushed
through the complete flow targeting the actual iCE40UP5K / SG48 package:

```sh
export PATH=/opt/oss-cad-suite/bin:$PATH
yosys -m ghdl -p "ghdl --std=93 top.vhd -e top; synth_ice40 -top top -json top.json"
nextpnr-ice40 --up5k --package sg48 --pcf smoke.pcf --json top.json --asc top.asc --freq 12
#   → "Program finished normally", max freq 86.71 MHz (PASS at 12.00 MHz)
icepack top.asc top.bin          # → valid 104,090-byte bitstream
icetime -d up5k top.asc          # → reads UP5K chipdb, timing estimate 80.62 MHz
```

Result: **full GHDL → Yosys → nextpnr-ice40 → icepack → icetime chain works for VHDL-93 RTL
on the UP5K target.**

Invocation rules for all agents (from this test):

- The GHDL plugin must be loaded: `yosys -m ghdl` (or `plugin -i ghdl` inside a script).
  Plugin lives at `/opt/oss-cad-suite/share/yosys/plugins/ghdl.so`, found automatically when
  the suite is on PATH.
- Yosys `synth_ice40` takes **`-json`** output; nextpnr-ice40 consumes **`--json`**.
- VHDL is imported with `ghdl --std=93 <files> -e <top>` inside the Yosys script.
- UP5K chipdb ships with nextpnr (`--up5k --package sg48`); `icetime -d up5k` works out of the box.

### 3.2 GHDL `--std=93` simulation smoke test — PASS

```sh
ghdl -a --std=93 smoke.vhd
ghdl -e --std=93 smoke
ghdl -r --std=93 smoke --assert-level=error
```

All three stages completed without error. **The project must pass `--std=93` explicitly on
every `ghdl -a/-e/-r` invocation** — the default standard of GHDL 7.0.0-dev is newer than 93.

### 3.3 WSJT-X / wsprd reference decoder

- Installed: Debian package **`wsjtx` 2.7.0+repack-1** (upstream version **2.7.0**), binary at
  **`/usr/bin/wsprd`** (standalone CLI decoder: `wsprd <file.wav|file.c2>`).
- **Citation for later phases:** all protocol timing constants (especially the 1 s vs. 2 s
  TX-start offset flagged in plan §0.1/§37) must be resolved against **WSJT-X 2.7.0**. Exact,
  version-matched source is re-derivable:
  ```sh
  apt-get source wsjtx        # → wsjtx_2.7.0+repack.orig.tar.xz
  # dsc  SHA256 4cd933f22fdce72fc9904dfb261bbb8e882c7f1dc41cbee40324a583f171e949
  # orig SHA256 c4687b322ed36d3c526ed32e99ea48023eb76542c004a0d4658e58d8ddbf3538
  ```
  Record the resolved value in `docs/protocol.md` citing this version.
- Rationale: installing the OS package is far more practical than building `wsprd` from source
  on this host, and the Debian package provides the identical `wsprd` binary. The GUI
  (`wsjtx`) is also available for interactive verification.

---

## 4. iCEBreaker hardware / USB programming

**Status: hardware NOT attached during setup — this item could NOT be verified on real
hardware. It is not a tool failure.**

```sh
$ lsusb | grep -i 0403
NO FTDI/FT2232H device found in lsusb
```

Host-side preparation complete:

- `iceprog` installed via oss-cad-suite and functional (usage output).
- USB access rule at **`/etc/udev/rules.d/99-icebreaker.rules`** (site-local copy — the
  original Debian `fpga-icestorm` package rule was removed with the package):
  ```
  ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0660", GROUP="plugdev", TAG+="uaccess"
  ```
  This matches the iCEBreaker's FT2232H bridge (VID:PID `0403:6010`). Rules reloaded
  (`udevadm control --reload-rules`).
- The current user is a member of `plugdev`.

**When the board is plugged in**, verify with:

```sh
lsusb | grep -i '0403:6010'   # device present
iceprog -t                    # cable test / device probe (no bitstream written)
```

If `iceprog -t` still fails after attach:
`sudo udevadm control --reload-rules && sudo udevadm trigger`.

---

## 5. Repository skeleton

Created exactly as specified in the plan §27 "Recommended Repository Structure". (Historical note
from setup time: the files started as **empty placeholders**; they have since been implemented by
the phase agents — see `docs/architecture.md` §12 for the current status. Genuinely empty today:
`src/clock/clock_control.vhd`, `tools/inspect_wspr.py`, `docs/rf.md`, `docs/verification.md`,
`docs/lab.md`.) The pre-existing `doc/` directory (orchestrator plan,
agent briefs, scoping decision) is a different, pre-existing directory and is left untouched;
the plan-specified `docs/` directory exists alongside it.

---

## 6. Reproducing this environment elsewhere

On Debian 13 (trixie):

```sh
# 1. OS/reference packages
sudo apt-get update
sudo apt-get install -y wsjtx python3-numpy git make libftdi1-2
sudo apt-get source wsjtx   # optional: version-matched WSJT-X 2.7.0 source for citation

# 2. oss-cad-suite (pinned release)
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-09-27/oss-cad-suite-linux-x64-20260927.tgz
echo "8af3500957e8a304a9bb67ecbcd1e9a7a8bc6ae0813075cc812bfac6143aed86  oss-cad-suite-linux-x64-20260927.tgz" | sha256sum -c
sudo tar -xzf oss-cad-suite-linux-x64-20260927.tgz -C /opt    # → /opt/oss-cad-suite (2.5 GB)

# 3. PATH hook (login shells)
sudo tee /etc/profile.d/oss-cad-suite.sh >/dev/null <<'EOF'
if [ -f /opt/oss-cad-suite/environment ]; then
    case ":$PATH:" in *:/opt/oss-cad-suite/bin:*) ;;
    *) . /opt/oss-cad-suite/environment ;; esac
fi
EOF

# 4. USB access for the board (rule + group; re-login after group change)
sudo tee /etc/udev/rules.d/99-icebreaker.rules >/dev/null <<'EOF'
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0660", GROUP="plugdev", TAG+="uaccess"
EOF
sudo udevadm control --reload-rules
sudo usermod -aG plugdev "$USER"

# 5. Verify
source /opt/oss-cad-suite/environment && yosys -V && ghdl --version | head -1
```

Version drift: oss-cad-suite releases are dated snapshots — pin the exact tarball + sha256
above. Component versions inside this build:

| Component | Pinned version |
|---|---|
| Yosys | 0.69+154 (git sha1 `30d62572e`) |
| GHDL | 7.0.0-dev (`6.0.0.r515.g6ea214092`) |
| nextpnr | 0.11.1-34-gc4fbb55a |
| IceStorm tools | bundled 20260927 build |
| GHDL-yosys plugin | bundled `ghdl.so` |
| WSJT-X (wsprd) | 2.7.0 (Debian `2.7.0+repack-1`) |
| numpy | 2.2.4 |
