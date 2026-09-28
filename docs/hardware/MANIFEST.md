# Hardware archive manifest — original documents

> Primary sources for the pin assignments, electrical assumptions and bring-up procedures.
> Every file lists its origin, retrieval date and SHA-256 (first 16 hex chars; full hash via
> `sha256sum`); verify before trusting a copy. Retrieval dates: **2026-09-28**. All vendor
> datasheets were fetched by hand — their hosts are bot-protected against scripted download.
> Content note: verify by *text*, not by PDF Title metadata — the Lattice file's embedded
> title is stale template junk ("Gms-d1 GPS Antenna Module…") while its content is the iCE40
> UP/HX family data sheet (checked: contains iCE40, UP5K, SG48).

## Archived — board hardware (verified)

| File | Origin | SHA-256 (first 16) | Role |
|---|---|---|---|
| `icebreaker-v1.1a-schematic.pdf` | Codeberg `icebreaker-fpga/icebreaker` @ `7ac3d6c`, `hardware/v1.1a/` | `37ef34074e8f20d2` | current-generation board schematic (R1) |
| `icebreaker-v1.0e-schematic.pdf` | same repo, `hardware/v1.0e/` | `5731b2530eeee2ea` | schematic contemporary with the pinned examples PCF (R1) |
| `icebreaker-v1.0b-pinout-legend.jpg` | same repo, `img/` | `e662a77c264e637c` | **pinout image** — PMOD/LED/header legend (R1) |
| `icebreaker-v1.0b-pinout-legend-jumpers.jpg` | same repo, `img/` | `5cf3423047ba83c6` | jumper configuration legend (R1) |
| `icebreaker-v1.0a-pinout-legend.jpg` | same repo, `img/` | `1c0e3dec06d6d6a2` | earlier-revision pinout legend (R1 cross-check) |
| `icebreaker-block-diagram.jpg` | same repo, `img/` | `db04ba26cc782b13` | board block diagram |
| `icebreaker-examples_cb9e674c.pcf` | GitHub `icebreaker-fpga/icebreaker-examples` @ **`cb9e674c`** (the pinned commit), `icebreaker.pcf` | `baa1ee9cfc44b66b` | **provenance of our PCF base rows** (clk 35, LEDR_N 11, LEDG_N 37, BTN_N 10, RX 6, TX 9); the GPS/RF rows in `constraints/icebreaker.pcf` are this file's documented additions |

## Archived — vendor datasheets (verified by text content)

| File | Origin (hand-fetched) | SHA-256 (first 16) | Role |
|---|---|---|---|
| `ice40up5k-datasheet.pdf` — *iCE40 UP/HX Family Data Sheet* (54 pp) | https://www.latticesemi.com/en/Products/FPGAandCPLD/iCE40 | `c14188010ff32f62` | R6: per-pin drive limits, DC/rail specs, timing tables |
| `pmodgps-rm.pdf` — *PmodGPS Reference Manual* (6 pp) | https://digilent.com/reference/pmod/pmodgps/start | `a548e73e7b501fa1` | R2/R3/R4: I/O level, 1PPS behaviour, UART format |
| `pa6h-datasheet.pdf` — *GlobalTop FGPMMOPA6H (PA6H)* | https://www.gtop-tech.com/ (PA6H product page) | `a2d6e81e3350090f` | R2/R3: electrical specs + 1PPS (cited in spec §10) |
| `ft2232h-datasheet.pdf` — *FTDI FT2232H* (69 pp) | https://ftdichip.com/ (FT2232H → Documents) | `ab042035a42fb4f9` | stage 0: programming-interface behaviour |

Note: the full KiCad projects (`.kicad_pcb`, `.kicad_sch`) remain upstream in the Codeberg
repository — not mirrored here to keep the archive lean; retrieve them from the repo above if
layout-level review is needed. The board **revision of the physical unit is still
PENDING-HARDWARE (R1)** — the v1.0b legend and both schematics are archived so any revision
can be checked on arrival.

## Status: complete

Nothing is outstanding. Every document backing a ratification item in `docs/hardware.md` §5
is now on disk with a recorded hash. If a vendor publishes a newer revision, add it under a
versioned filename and extend the table — never overwrite an archived original.
