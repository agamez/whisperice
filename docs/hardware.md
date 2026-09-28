# Hardware bring-up runbook — for the agent with hardware access

> **Who this is for.** An agent (or careful human) working on a computer that *is* connected to
> the rig. This machine has no hardware access; everything software-side is finished and
> verified (13/13 testbenches, bitstream at 31.09 MHz, decoder adjudication passing — see
> [`docs/verification.md`](verification.md)). Your job is the part that cannot be simulated:
> ratify the PENDING-HARDWARE assumptions (spec §16), bring the beacon up in stages, and feed
> every finding back. This is the plan §28 Agent A/F hardware role.
>
> **Where results go.** Your working log is [`docs/lab.md`](lab.md) (currently empty — it is
> your notebook). Ratifications update this file's §5 tables, [`docs/environment.md`](environment.md)
> §4, [`docs/rf.md`](rf.md) §8, and [`docs/verification.md`](verification.md) §5. Commit after
> every completed stage.

---

## 1. Binding rules (these outrank convenience)

1. **NEVER radiate the bench message.** The compiled message is "K1ABC FN42 37" — a simulation
   vector (plan §25). All agent work happens into a **50 Ω dummy load** (rated ≥ 1 W, ideally
   more). An antenna is a licensing event, not an engineering step.
2. **Over-the-air transmission is a hard stop-gate.** It requires a licensed operator, the
   operator's own callsign compiled into `top.vhd`, a reduced slot mask, and explicit
   authorization recorded in `docs/lab.md`. You do not pass this gate autonomously (§6, stage 6).
3. **Do not silently change RTL to fit hardware.** If the hardware contradicts the RTL or the
   frozen spec, document the mismatch, report it back, and let the owning side decide
   (orchestrator rule 4). Mechanical pin-mapping fixes are the exception — apply them with a
   commit note and flag them for review.
4. **Protocol constants are frozen.** Any constant change forces re-review of the golden
   vectors (rule 5). Hardware findings adjust *ratification documents*, not the protocol.
5. **VHDL-93 discipline** if you must rebuild: `--std=93` everywhere; `make sim` must stay
   13/13; `make build` must stay timing-clean.
6. **Electrical safety**: power off before rewiring; check supply polarity and the Pmod keying
   before power-on; if anything smells, heats, or short-circuits — power off and document.

## 2. The expected rig

| Item | Expected | Provenance |
|---|---|---|
| FPGA board | iCEBreaker (Lattice iCE40UP5K, SG48) | plan §3.1 |
| Programming | onboard FT2232H USB (VID:PID **0403:6010**) | `iceprog`; udev rule below |
| GPS module | Digilent PmodGPS (GlobalTop FGPMMOPA6H/MT3329 class) on **PMOD 1A** | spec §10 |
| NMEA in | PmodGPS TX → FPGA pin **47** (P1A3) | `constraints/icebreaker.pcf` |
| 1PPS in | PmodGPS PPS → FPGA pin **45** (P1A4, ~100 ms pulse) | `constraints/icebreaker.pcf` |
| RF out | FPGA pin **28** (P1B10) → series R (≥ 330 Ω to start, see rf.md §4) → dummy load | spec §11 |
| Clock | onboard 12 MHz oscillator, pin 35 | spec §8 |
| LEDs | led1 = pin 11 (LEDR_N), led2 = pin 37 (LEDG_N), both **active-low** | spec §11 |

Pin provenance: official iCEBreaker examples @ `cb9e674c` (never invented; AGENTS.md rule 4).
**The originals are archived in [`docs/hardware/`](hardware/MANIFEST.md)** — both board
schematics, the pinout legend images, the provenance PCF itself, and the vendor datasheets as
they are fetched (see that manifest's manual-fetch list for R2/R3/R4/R6 backing documents).
**Verify the Pmod header positions against the Digilent reference and the board silkscreen
before first power-on** — that physical check is ratification item R1 below.

## 3. New-machine setup (do this BEFORE touching hardware)

Debian/Ubuntu assumed; adapt package names elsewhere. Order matters — reproduce the *software*
results first, so any later failure is provably hardware.

1. **Repository**: `git clone <repo>` and check out `master` (≥ `56b145f`).
2. **Toolchain — pinned, not latest**: install **oss-cad-suite release 2026-09-27**
   (YosysHQ GitHub releases) to `/opt/oss-cad-suite`; add
   `/opt/oss-cad-suite/bin` to PATH via `/etc/profile.d/oss-cad-suite.sh`. Debian's own yosys
   lacks the GHDL plugin — do not substitute versions silently (GHDL 7.0.0-dev, Yosys
   0.69+154 were verified here; record yours in `docs/environment.md` §2).
3. **udev**: create `/etc/udev/rules.d/99-icebreaker.rules` containing exactly
   `ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6010", MODE="0660", GROUP="plugdev", TAG+="uaccess"`
   then `sudo udevadm control --reload-rules` and re-plug. Be in the `plugdev` group.
4. **Decoder & tools**: `sudo apt-get install -y wsjtx python3-numpy make` (pins wsprd
   2.7.0+repack-1). Beware: with the oss-cad-suite profile loaded, its `py3bin` shadows
   `/usr/bin/python3` which has numpy — call `/usr/bin/python3` explicitly (environment.md
   §2 caveat).
5. **Software-only reproduction gate** (all must pass before hardware work):
   `make sim` → **13/13 PASS**; `make clean && make` → `build/top.bin`, icetime ≥ 12 MHz PASS;
   `python3 tools/make_wspr_wav.py` + `wsprd` → decodes `K1ABC FN42 37` (verification.md §2).
   A failure here is a toolchain/version problem — fix it now, not mid-bring-up.
6. **First hardware contact**: `lsusb | grep 0403:6010`, then `iceprog -t`. Record both.

## 4. Instruments you will need

On-board observability is exactly two LEDs (plan §32) — everything else is external:

- **USB logic analyzer** (8 ch, sigrok/PulseView) on the Pmod 1A header: `uart_rx`, `pps`,
  ground — this is your window into NMEA bytes and the 1PPS shape.
- **Oscilloscope** on `rf_out` (pin 28 / P1B10): envelope timing, 1-bit waveform.
- **Receiver/SDR** covering the chosen band (80 m: 3 570 100 Hz; a upconverter or direct-sampling
  SDR for HF) + an antenna **into a dummy load** or a short whip *far from any licence
  concern* — no, for agent work: **dummy load, and couple the receiver inductively** (a few
  turns of wire near the load) so nothing radiates.
- Multimeter for the PmodGPS I/O level check.

## 5. Ratification checklist (spec §16) — do these FIRST

Each item: assumption → test → record. A mismatch is a **finding**, not a failure: record it,
report it, and let the software side react (rule 1.3).

| ID | Assumption (frozen) | Test | Record in |
|---|---|---|---|
| R1 | Pin mapping matches the physical board | continuity-check PCF pins ↔ headers ↔ Pmod pins | this file §7, `lab.md` |
| R2 | PmodGPS I/O ≈ 2.8 V TTL | scope/multimeter on TX idle-high level with module powered | spec §16 row, `gps.md` |
| R3 | 1PPS ≈ 100 ms pulse | logic analyzer; also confirm it appears only once per second and aligns with NMEA seconds | `gps.md`, this file |
| R4 | Module emits `$GPRMC` at 9600 8N1 | logic analyzer capture: inventory every sentence type + baud | spec §16, `gps.md` |
| R5 | RF pin = P1B10/pin 28 usable | scope on rf_out during stage 3 | `rf.md` §8 |
| R6 | iCE40 pin drive limit | Lattice iCE40UP5K data sheet → set the final series R / buffer decision | `rf.md` §4 |

## 6. Bring-up stages — in order, each gated on the previous

**Stage 0 — identity.** `iceprog -t` prints the board. `lab.md`: date, cable, USB tree.

**Stage 1 — bitstream & heartbeat.** `make clean && make` on the new machine, then
`iceprog build/top.bin`. Expect: **led1 blinking with a 1 s period** (0.5 s high/low), led2
dark (no GPS yet). This proves clock, POR, fabric, and the PCF. *Abort*: no blink → check
program succeeded (`iceprog` verify), then PCF/pin ratification R1.

**Stage 2 — GPS chain.** Attach PmodGPS (antenna with sky visibility — windowsill works,
basements do not). Within ~1 min of lock expect: logic analyzer shows NMEA at 9600 8N1 (R4);
1PPS pulses ~100 ms (R3); **led2 lights** when UTC is loaded *and* the first calibration window
completes (2 PPS intervals × CALIBRATION_SECONDS... the shipped default is 8 s — wait ≈ 10 s
after led2's first darkness). led2 dark forever ⇒ walk the failure matrix (§9). Record: sentence
inventory, I/O level (R2), pulse width.

**Stage 3 — first TX into the dummy load.** Leave the rig until the next even minute, second 1.
Expect: **rf_out bursts for 110.592 s** starting at second = 1 of the even minute (± the GPS's
own timing error), then silence; led2 drops during the post-TX recalibration window and returns.
Scope check: 1-bit square-wave-ish activity whose envelope matches the frame; the *apparent*
frequency of the pattern is the folded ~1.86 MHz for the 30 m default carrier — **this is the
documented Nyquist behaviour, not a bug** (rf.md §1). Record: start instant vs GPS time (the DT
question, live), burst length, envelope.

**Stage 4 — spectrum measurement.** SDR/SA capture of the dummy-load leakage (inductive
coupling). Measure: fundamental, the image lines, the 12 MHz feedthrough, harmonics, noise
floor. Compare against the rf.md §1/§2 sinc predictions. Outcome: **ratify or correct** the
band table weights and pick the initial band (recommendation: 80 m, 3 570 100 Hz — direct
fundamental). Update `rf.md` §8 items to "measured".

**Stage 5 — loopback decode (the crown test).** Feed the receiver's 120 s recording
(12 kHz, 16-bit mono WAV named `YYMMDD_HHMM.wav` — wsprd parses the name) into `wsprd -v -f
<dialed MHz>` exactly as `docs/verification.md` §2. Expect: **`K1ABC FN42 37`**, DT ≈ 0 (the
beacon's +1.000 s start vs the slot), drift ≈ small. A decode here proves the whole chain on
real silicon. Record the verbatim output in `lab.md` and `verification.md` §5.

**Stage 6 — over the air. STOP — human gate.** Only with: a licensed operator present, the
operator's callsign/grid/power compiled into `top.vhd` (constants `MSG_*`), the slot mask
reduced from all-ones (WSPR etiquette, plan §35), authorization recorded in `lab.md`. Then:
attenuated antenna test → remote receiver decode → **WSPRnet spot** (plan §26/§38: the success
criterion). Record the spot link.

## 7. Ratification record (fill in)

| ID | Item | Result | Date | Deviation & consequence |
|---|---|---|---|---|
| R1 | Pin mapping | ☐ confirmed | | |
| R2 | GPS I/O level (≈ 2.8 V) | ☐ confirmed | | |
| R3 | 1PPS width (~100 ms) | ☐ confirmed | | |
| R4 | RMC @ 9600 8N1 | ☐ confirmed | | |
| R5 | RF pin P1B10 | ☐ confirmed | | |
| R6 | Drive limit / series R | ☐ decided | | |

## 8. Feedback loop — what to send back to the software side

A structured findings list after every stage:

- **Confirmed** — assumption held; which doc row was updated.
- **Changed** — a document needed correcting (e.g. actual pulse width); the edit + commit.
- **Broken** — hardware contradicts RTL/spec: the evidence (capture, photo, scope shot
  reference), the suspected owner (which block, which doc section), and *no silent fix*.
- **Blocks** — anything that halts the sequence and what decision it needs.

Commit style: `Hardware bring-up stage N: <what was learned>` — one commit per stage, docs
included. Never commit binary captures to the repo; reference them by filename/hash in
`lab.md`.

## 9. Troubleshooting map

| Symptom | Likely cause | Action |
|---|---|---|
| `lsusb` shows no 0403:6010 | cable/port/udev | re-plug, `udevadm control --reload-rules`, try another cable (data vs charge!) |
| `iceprog: Cannot find iCEBreaker` | permissions or device busy | check `plugdev`, udev rule, no other instance running |
| led1 never blinks | bitstream/PCF/power | re-run `iceprog` with verify; re-check stage-1 gate; scope the 12 MHz pin |
| led2 never lights | no GPS lock / no RMC / calibration error | §9 GPS triage: antenna+sky → R4 capture → sentence inventory; then check `CAL_MIN/MAX_HZ` bounds vs the *actual* measured count (a wildly off oscillator trips the ±1000 ppm bounds — that is the design working) |
| led2 dark *after* a TX | recalibration window — normal for ~10 s | wait; if permanent, calibration is failing post-TX — capture it |
| rf_out silent at :01 | UTC invalid (no GPS) or calibration error or wrong minute (odd) | led2 state first; then scheduler `state_o` is unobservable on hardware — reproduce in sim with the captured NMEA |
| rf_out continuous/not 110.6 s | modulator stuck — do not power-cycle repeatedly; capture and report | this is a Broken finding (rule 1.3) |
| decode fails, signal visible | dial error beyond search, DT off, or folded-image filtering | check receiver dial vs the ratified carrier; widen `wsprd` search (`-w`); compare against the §2 synthetic path |
| decode fails, no signal visible | filter/load/gain chain | stage 4 measurements first — never tune blind |

## 10. Sources

- `doc/wspr_icebreaker_orchestrator_plan.md` §3.1–3.2 (hardware), §19 (RF chain), §25 (legal),
  §30-F (hardware acceptance), §31 (failure behavior), §32 (diagnostics), §38 (success).
- `docs/spec.md` §10–§11 (pins/levels), §16 (PENDING-HARDWARE — the table this runbook retires).
- `docs/environment.md` (toolchain pin + reproduction), `docs/rf.md` (chain + measurements),
  `docs/verification.md` §2/§5 (decoder adjudication), `docs/gps.md` (GPS contracts),
  `constraints/icebreaker.pcf` (pins), `docs/lab.md` (your log).
- iCEBreaker examples @ `cb9e674c` (pin provenance); Lattice iCE40UP5K data sheet (R6);
  Digilent PmodGPS reference (wiring).
