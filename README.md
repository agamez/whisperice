# wspr-icebreaker

An autonomous, protocol-compliant **WSPR beacon** on the [iCEBreaker](https://github.com/icebreaker-fpga/icebreaker)
board (Lattice iCE40UP5K) with a Digilent PmodGPS, written entirely in **VHDL-93**.

The design obtains UTC from GPS (NMEA + 1PPS), calibrates its own 12 MHz clock against the
1PPS reference before every transmission, and emits a continuous-phase 4-FSK WSPR signal
(162 symbols, 110.592 s) from a single GPIO through external filtering. The full architecture,
phases and frozen protocol constants are described in
[`doc/wspr_icebreaker_orchestrator_plan.md`](doc/wspr_icebreaker_orchestrator_plan.md).

> ⚠️ Transmitting over the air requires a valid amateur radio license, your own callsign, and
> compliance with local band plans. Example vectors such as `K1ABC FN42 37` are for
> simulation/bench use only.

## Toolchain

The complete open-source iCE40 flow plus a VHDL-93 simulator and WSPR reference decoder:

| Purpose | Tool |
|---|---|
| Synthesis | Yosys 0.69+154 with GHDL plugin (oss-cad-suite 2026-09-27) |
| Place & route | nextpnr-ice40 0.11.1 |
| Bitstream / programming | Project IceStorm (`icepack`, `iceprog`, `icetime`) |
| Simulation | GHDL 7.0.0-dev (used strictly with `--std=93`) |
| Reference decoder | `wsprd` from WSJT-X 2.7.0 |
| Reference model / tooling | Python 3.13 + numpy 2.2.4 |

Exact versions, install methods, verification commands and the current hardware status are
documented in **[docs/environment.md](docs/environment.md)**.

## Repository layout

```
constraints/   iCEBreaker pin constraints (.pcf)
src/           VHDL-93 RTL (clock/, gps/, timing/, nco/, wspr/, top)
sim/           VHDL-93 testbenches
reference/     Independent WSPR reference model + test vectors
tools/         Helper scripts (NCO constant calculation, WSPR inspection)
docs/          Architecture, protocol, GPS, RF, verification, lab notes, environment
```

The layout follows the plan's "Recommended Repository Structure" (§27) exactly. The repository is
fully implemented through integration (Phases 0–5 plus the pedagogical review): all RTL blocks have
committed testbenches, `make sim` runs 13/13 passing, `make` produces `build/top.bin`. Genuinely
empty placeholders that remain: `src/clock/clock_control.vhd`, `tools/inspect_wspr.py`,
`docs/rf.md`, `docs/verification.md`, `docs/lab.md` (status in `docs/architecture.md` §12).

## Building (after Phase 1)

```sh
make            # synthesize + place&route + bitstream
make prog       # program the iCEBreaker with iceprog
make sim        # run GHDL testbenches (--std=93)
make clean
```

## License

MIT — see [LICENSE](LICENSE).
