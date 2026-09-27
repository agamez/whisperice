# Scoping Decision Record — 001

> Produced by the Scoping Agent per [`doc/setup_agents.md`](setup_agents.md) on **2026-09-27**,
> against repository state `339ca51` ("Add AGENTS.md with agent instructions and workflow rules").
> This is a decision record only — no implementation work was performed as part of producing it.

## 1. Decision

**(b) Single general-purpose executor** carries the work for **Phase 0 (frozen documentation &
requirements)** and **Phase 1 (iCEBreaker infrastructure + reproducible build flow)**.

Not the full A–G structure. All seven named agents from plan §28 are **deferred**; the role
table stays in force as the ownership map for the escalation described below.

### Operating constraints within single-executor mode

These apply now; they do not wait for escalation:

- The executor remains bound by plan §29 Rules 1–6 (especially Rule 2: no block is done
  without RTL + testbench + documentation).
- **Review separation is enforced by passes, not by named agents:** after Phase 0 delivers
  `docs/spec.md`, a *distinct* reviewer pass (separate agent invocation) checks the frozen
  spec — including the 1 s vs. 2 s TX-start offset resolution against wsprd 2.7.0 — before any
  RTL is written. The implementer never reviews their own block, per the brief's
  "never" rule.
- No protocol-critical constant (FEC polynomials, sync vector, interleaver, timing figures) is
  finalized without its citation and the vector re-review required by plan Rule 5.

## 2. Assessment (one sentence per scoping question)

1. **Scope size:** Only Phase 0 and Phase 1 are startable and they are strictly sequential —
   Phase 0 gates all RTL writing (plan §4: "Before writing any RTL") and Phase 1 gates every
   hardware-dependent phase — so there is nothing to run concurrently.
2. **Isolation risk:** Genuine but latent — codec/FEC/sync/timing constants are
   protocol-critical, yet with a single worker there is no concurrent writer whose "helpful
   edit" could silently corrupt them; the risk returns exactly when parallel work starts.
3. **Parallelism value:** None available — Agent C's codec (the only block not hardware-bound)
   still cannot start because Phase 0's frozen spec does not exist yet, and Agents B/D/F blocks
   all need Phase 1's reproducible build flow for testbench and integration.
4. **Review need:** Yes, and it is satisfied without pre-spawning agents — Phase 0's spec and
   Phase 1's flow are the two artifacts the entire project inherits, and a distinct reviewer
   *pass* (separate invocation) meets the Agent E/G separation the brief mandates.
5. **Coordination overhead:** Spawning seven named agents now means five of them (B, C, D, E,
   G) would idle waiting on Phase 0/1 outputs — pure Rule 1 file-locking and hand-off cost
   with zero parallel return.

## 3. Agent activation map

| Agent | Status now | Activates when |
|---|---|---|
| A — Hardware/docs | Deferred | Phase 0 hardware/PCF verification could be folded into the executor's Phase 0; a dedicated A is warranted only if electrical-level verification (plan §3.2) turns into real lab work |
| B — GPS/timing | Deferred | After Phase 1 flow is reproducible (its testbenches need the build flow) |
| C — WSPR codec | Deferred | After Phase 0's `docs/spec.md` is frozen (its RTL is blocked on frozen constants; its *reference vectors* may be prepared alongside Phase 0 by the executor) |
| D — NCO/modulator | Deferred | After Phase 1 flow is reproducible |
| E — Verification | Deferred | Reappears as a distinct reviewer pass immediately after Phase 0 (spec) and Phase 1 (flow); becomes a standing role once codec/NCO RTL exists |
| F — Integration | Deferred | Phase 1's Makefile/constraints work is done by the executor; F activates when multiple agent-owned blocks must be integrated |
| G — Pedagogical review | Deferred | First full pass after the Phase 0/1 chain lands |

## 4. Trigger for re-running this decision

**Re-run when Phase 1 completes**, i.e. when `make clean && make` reproducibly produces a
valid UP5K bitstream and the flow is documented. At that point evaluate whether ≥2 blocks with
no shared files are simultaneously unblocked — the expected case being **C (codec, blocked only
on the frozen spec) vs. D (NCO/modulator) vs. B (GPS/timing)** — and at least one touches
protocol-critical constants. If both conditions hold, escalate to the specialized structure
for the parallel stretch; if not, stay with the single executor and re-scope again after the
next phase.

*Secondary trigger:* any time work would give one agent both implementation and adversarial/
pedagogical review of the same block — that must be split regardless of structure chosen.
