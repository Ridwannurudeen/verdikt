# Verdikt — Economic Security Analysis

> **File location note:** the project's `docs/` directory is gitignored
> (`.gitignore` line 18), so this companion to `ECONOMICS.md` lives at the repo
> root rather than under `docs/`.

This doc analyzes Verdikt's incentive surface honestly: what the deployed
contracts actually deter, where the gaps are, and which hardening steps are
**shipped** versus **proposed**. Every number is grounded in source; proposals
are labelled `[PROPOSAL]` and are *not* in the contracts today.

It extends `ECONOMICS.md` (fee model + anti-frivolous-**appeal** break-even). The
new contribution here is the round-0 **dispute** side (which `ECONOMICS.md` does
not bond), the validator trust model, and a griefing inventory.

Scope of code cited:

- `src/VerdiktEscrow.sol` — native-STT two-party escrow + dispute/appeal/slash.
- `src/VerdiktTokenEscrow.sol` — ERC-20 variant of the same.
- `src/VerdiktCourt.sol` — panel pricing, sizing, consensus, prompt handling.
- `src/VerdiktMarketplace.sol` — operator stake / challenge / slash / routing.
- `src/VerdiktKeeperBounty.sol` — permissionless finalization incentive.

---

## 1. Anti-spam / frivolous disputes

### 1.1 What a dispute costs today (shipped)

Opening a dispute convenes a panel and the disputer pre-funds the panel fee:

- `VerdiktEscrow.dispute` (`src/VerdiktEscrow.sol:129-135`) requires
  `msg.value >= court.quoteOpen()`, forwards exactly that to `openCase`, and
  refunds the excess at the consumer boundary (`_refundExcess`,
  `src/VerdiktEscrow.sol:328-330`).
- `quoteOpen()` (`src/VerdiktCourt.sol:366-368`) = `_depositFor(_panelSize(0))`
  = `platform.getAdvancedRequestDeposit(panel) + perAgentPrice * panel`
  (`src/VerdiktCourt.sol:333-335`), with `perAgentPrice = 0.07 ether`
  (`src/VerdiktCourt.sol:24`) and `_panelSize(0) = 5`
  (`src/VerdiktCourt.sol:324-326`).
- Live-verified all-in trial fee ≈ **0.40 STT** for a panel of 5 (per
  `ECONOMICS.md` §1; determinism gate requestId 3486438).

So spam has a hard per-dispute floor of ≈ 0.40 STT, and that STT is **consumed
by validator inference** — it is not recoverable even if the disputer is right.
A bot that opens 1,000 junk disputes burns ≈ 400 STT with zero refund. That is a
real and sufficient deterrent against *volume* spam (many cheap disputes).

The caller can also request a smaller trial panel
(`dispute(dealId, evidence, trialPanel)`, `src/VerdiktEscrow.sol:140-146`;
`MIN_TRIAL_PANEL = 3`, `src/VerdiktCourt.sol:40`), which lowers the fee toward
≈ 0.3 STT but also weakens the majority — it exists for degraded validator sets,
not as a spam discount worth exploiting.

### 1.2 The gap: round 0 has a fee but no slashable bond

Here is the honest weakness. **At round 0 the disputer risks only the fee, not a
bond posted against the deal value.** Only *appeals* post a slashable stake:

- Appeal stake = `appealStakeBps` (1000 = 10%) of the deal,
  `src/VerdiktEscrow.sol:17,225`, slashed in `onVerdict` if the verdict is
  upheld (`src/VerdiktEscrow.sol:258-274`).
- The round-0 dispute path has **no equivalent** — `dispute`/`convene` capture
  `fee` only and never record a disputer bond.

Why this matters: the fee is a *flat* cost (≈ 0.40 STT) while the prize from a
successful frivolous dispute is *proportional* to the deal value `A`. Reusing the
expected-value frame from `ECONOMICS.md` §2, a disputer with belief `q` that the
panel rules their way is `+EV` to dispute when:

```
q · A  >  f0            →     q*  =  f0 / A          (current round 0, no bond)
```

with `f0 ≈ 0.40 STT`. The break-even belief collapses toward zero as the deal
grows:

| Deal `A` | `q*` to make a *frivolous* dispute +EV (today) |
|---|---|
| 1 STT   | 0.40  (40%) |
| 5 STT   | 0.080 (8.0%) |
| 10 STT  | 0.040 (4.0%) |
| 100 STT | 0.004 (0.4%) |
| → ∞     | → 0 |

For a 100 STT deal, a disputer needs only ~0.4% confidence that the AI panel
mis-rules in their favor to make a coin-flip-grade gamble pay. The fee deters
*volume*, but for *high-value single deals* it barely deters a one-shot
roll-of-the-dice dispute. The appeal layer is already bonded against exactly this
shape; round 0 is not.

### 1.3 `[PROPOSAL]` A minimal round-0 dispute bond

Add a bond symmetric to the existing appeal stake, refunded on a win, partially
slashed on a loss. This is **not in the contracts** — it is a proposed addition.

Proposed mechanism (mirrors the appeal machinery already in `onVerdict`):

1. New owner param `disputeBondBps` (suggest **250–500 bps**, i.e. lower than the
   10% appeal stake, so round 0 stays the more accessible tier).
2. `dispute` / `convene` capture `bond = amount * disputeBondBps / 10000` in
   addition to the panel fee, and record the disputer's address (reuse an
   `AppealInfo`-style struct).
3. In `onVerdict`, if the verdict goes **against** the disputer, slash the bond
   using the *existing* `keeperCutBps` split — `cut` to treasury, remainder to
   the counterparty (identical to `src/VerdiktEscrow.sol:264-268`). If it favors
   the disputer (or SPLIT), refund the bond in full via `_credit`.

Break-even with a bond `B = (disputeBondBps/10000)·A`. The cost is now `f0`
always plus `B` only when the disputer loses (prob `1 − q`):

```
q · A  >  f0 + (1 − q) · B
q · (A + B)  >  f0 + B
                f0 + B
q*  =  ───────────────────
                A + B
```

This is the **same formula** as the appeal break-even in `ECONOMICS.md` §2 with
`f → f0` and `S → B`. With `f0 = 0.40 STT` and `B = 0.05·A` (500 bps):

| Deal `A` | bond `B` (5%) | `q*` with bond | `q*` today (no bond) |
|---|---|---|---|
| 1 STT   | 0.05 STT | 0.429 (42.9%) | 0.40  (40%) |
| 5 STT   | 0.25 STT | 0.124 (12.4%) | 0.080 (8.0%) |
| 10 STT  | 0.50 STT | 0.086 (8.6%)  | 0.040 (4.0%) |
| 100 STT | 5.0 STT  | 0.051 (5.1%)  | 0.004 (0.4%) |
| → ∞     | 0.05·A   | → B/(A+B) = **0.0476 (4.76%)** | → 0 |

The key shift: the bond replaces a break-even that **decays to 0** for large
deals with one that **floors at ≈ 4.76%** (the `B/(A+B)` asymptote). A frivolous
high-value disputer can no longer roll the dice on sub-1% confidence; they must
believe the panel will side with them at least ~5% of the time *and* accept that
they forfeit 5% of the deal to the counterparty when it doesn't. The slashed bond
also compensates the wrongly-dragged-in counterparty for the delay, exactly as
the appeal slash compensates the appeal winner.

**Trade-off (state it plainly):** a bond raises the bar to *access justice*. A
genuinely-wronged party with thin capital must now lock 5% of the deal and bears
slash risk if the AI errs against a correct claim. That is the cost of pricing
out spam. Mitigations that keep the bar low: (a) keep `disputeBondBps` modest and
below `appealStakeBps`; (b) the bond is fully refunded on a win, so it costs an
honest, correct disputer nothing but opportunity cost of locked capital; (c) the
`UNDECIDABLE`/SPLIT paths (`src/VerdiktEscrow.sol:290-308`) should refund rather
than slash, so an honest-but-ambiguous dispute is not punished. The `q*` floor is
a *parameter dial*, not a fixed tax — owner/timelock can tune it per court.

---

## 2. Validator honesty / the AI jury's incentives

### 2.1 The trust assumption, stated honestly

**Verdikt does not independently incentivize honest judging.** The panel is run
by Somnia's validator set: `_dispatch` calls
`platform.createAdvancedRequest(...)` (`src/VerdiktCourt.sol:241-250`) and the
verdict arrives via the platform callback `handleVerdict`
(`src/VerdiktCourt.sol:196-230`, gated `msg.sender == address(platform)`). The
per-agent fee (`perAgentPrice`, the platform deposit) is paid to validators for
running the inference **regardless of which label they return**. There is no
in-protocol reward for a "correct" verdict and no in-protocol slashing of a
validator that returns a bad one.

So the honest-judging guarantee is *inherited from Somnia*: Verdikt trusts that
Somnia's validators run the requested model on the requested prompt and report
the result faithfully, secured by Somnia's own validator staking/slashing — which
is outside Verdikt's contracts. **If Somnia's validator set is honest and live,
Verdikt's verdicts are honest; Verdikt adds no independent economic guarantee at
the validator layer.** This should be a headline assumption, not a footnote.

### 2.2 What Verdikt *does* add on top

Three accountability layers sit above the inherited validator trust:

1. **Byte-identical majority consensus.** Panels run with
   `ConsensusType.Majority` and `threshold = panel/2 + 1`
   (`src/VerdiktCourt.sol:237,241-250`). The verdict is a single short label from
   a constrained set (`PAYEE`/`PAYER`/`SPLIT…`, parsed in
   `src/VerdiktCourt.sol:339-349`), so honest jurors on the same prompt converge
   on the *same bytes*. A minority of deviating/faulty jurors is outvoted, and a
   panel that cannot reach threshold errors (`CaseStatus.Errored`,
   `src/VerdiktCourt.sol:210-221`) rather than rendering a coerced verdict — the
   consumer can `retry` (`src/VerdiktCourt.sol:173-181`). This bounds the damage
   a sub-majority of bad jurors can do to *zero* on the verdict itself.

2. **Determinism of the prompt the panel sees.** Every case snapshots the active
   prompt version at open time (`promptVersion`, `src/VerdiktCourt.sol:150`,
   append-only `_promptVersions`), evidence is wrapped in an `<evidence>` fence
   with `<`/`>` stripped (`_sanitizeEvidence`, `src/VerdiktCourt.sol:308-322`) so
   a party cannot break out and instruct the jury, and verified facts (if a
   registry is wired) are read once and rendered as authoritative above party
   claims (`_verifiedFacts`, `src/VerdiktCourt.sol:294-304`). All jurors see
   identical bytes, which is what makes byte-identical consensus meaningful and
   what makes a verdict auditable against the exact prompt that produced it.

3. **The marketplace stake / challenge / slash layer — at the *operator*
   level.** This is the only place Verdikt adds *its own* economic
   accountability, and it is critical to be precise: it bonds **court
   operators**, not Somnia validators. In `src/VerdiktMarketplace.sol`:
   - An operator must stake `minStake = 1 ether` to back a court
     (`backCourt`, `:71-79`).
   - Anyone can `challenge` a court's handling of a case with a
     `challengeBond = 0.2 ether` (`:110-116`).
   - Governance `resolveChallenge` (`:119-140`): an upheld challenge slashes
     `slashBps = 2000` (20%) of the operator's stake — half to treasury, the rest
     plus bond to the challenger; a rejected challenge pays the bond to the
     operator (anti-frivolous, symmetric to the appeal/dispute logic).
   - Routing is quality-weighted: `score` rewards rejected challenges (+1) and
     punishes upheld ones (×3), and `bestCourt` routes flow to high-score,
     cheap, well-staked courts (`:156-191`).

   So a court operator who runs a misconfigured or dishonest court (bad prompt,
   wrong `agentId`, censoring keeper) can be challenged, slashed, and starved of
   routing. This punishes the *operator's configuration and conduct*, which is
   the layer Verdikt controls; it still cannot punish an individual Somnia
   validator for a single bad inference.

### 2.3 Sybil considerations

- **Validator sybil** is out of Verdikt's hands — resistance is whatever Somnia's
  validator staking provides. The panel-size knob is the only lever: larger
  panels (trial 5, appeal 9, `src/VerdiktCourt.sol:36,324-326`) raise the cost of
  a colluding validator subset capturing a majority, but appeals are capped at
  `MAX_ROUND = 1` and the live Shannon subcommittee cap (~6, per `ECONOMICS.md`
  §1 caveat) limits how large a panel can realistically be today.
- **Court-operator sybil** (spinning up many courts to game routing) is gated by
  `minStake = 1 ether` *per court* (`src/VerdiktMarketplace.sol:74`) — each sybil
  court costs real capital that is slashable, and `score` starts at 0 with no
  rejected-challenge history, so sybils do not out-route an established court.
- **Disputer/party sybil** (one actor controlling both sides, or spamming
  disputes from many addresses) is gated by the per-dispute fee (§1.1) and, under
  the §1.3 proposal, by the bond. Note `createDeal` forbids self-dealing
  (`payee != msg.sender`, `src/VerdiktEscrow.sol:92`), but a single actor can
  still control two addresses; the fee/bond is what makes that uneconomic, not an
  identity check.

---

## 3. Griefing vectors

| Vector | Status | Mechanism / why |
|---|---|---|
| **Silent counterparty stalls settlement** | **Mitigated (shipped)** | Two-sided dispute path: `openDispute` records the opener's statement and sets `responseDeadline = now + responseWindow` (1 hour, `src/VerdiktEscrow.sol:56,166-174`); the counterparty may `submitEvidence` while open (`:177-185`); `convene` (`:189-200`) requires `block.timestamp >= responseDeadline || bothSpoke`, so a silent party cannot stall — the panel rules on a combined statement that fills the missing side with `"(no statement submitted)"` (`_combinedStatement`, `:202-208`). |
| **Reverting recipient bricks finalization** | **Mitigated (shipped)** | Pull payments everywhere. `onVerdict` only credits an internal ledger via `_credit` (`src/VerdiktEscrow.sol:245-275,321-326`); funds move only in `withdraw` (`:279-286`). A recipient whose `receive()` reverts harms only their own later withdrawal, not settlement. Same pattern in `VerdiktTokenEscrow` (`pending`/`withdraw`, `:195-226`), `VerdiktMarketplace` (`:144-151`), and `VerdiktKeeperBounty` payout. |
| **Stalled finalization (no one calls `finalize`)** | **Mitigated (shipped)** | `finalize` is permissionless (`src/VerdiktCourt.sol:185-192`) and `VerdiktKeeperBounty` adds the incentive: anyone funds a bounty, any keeper `finalizeAndClaim`s the pot (`src/VerdiktKeeperBounty.sol:28,52-65`). Funders can `reclaim` before it's claimed (`:38-48`). Liveness becomes a permissionless market. |
| **Fee-on-transfer / rebasing ERC-20** | **Mitigated (shipped, by rejection)** | `VerdiktTokenEscrow.createDeal` and `appeal` measure the actual balance delta and revert `"fee token unsupported"` if it ≠ `amount` (`src/VerdiktTokenEscrow.sol:98-100,167-169`). Fee-on-transfer tokens are *refused at the door* rather than silently under-credited. Native `VerdiktEscrow` is STT-only and immune. |
| **Prompt injection by a party** | **Mitigated (shipped)** | Evidence is fenced and `<`/`>` stripped (`_sanitizeEvidence`, `src/VerdiktCourt.sol:308-322`); the system/preamble prompts explicitly instruct the panel to treat fenced content as untrusted claims only (`src/VerdiktCourt.sol:114-117`). Deterministic stripping preserves consensus. Residual risk: a sufficiently clever non-bracket injection — defense-in-depth, not a proof. |
| **Direct `Court.openCase` overpayment not refunded to non-consumer callers** | **Known / partially mitigated** | Consumers forward the exact fee and get refunds (`_refundExcess`); a *direct* caller's overpayment is credited to `pendingRefunds` and withdrawable (`src/VerdiktCourt.sol:351-358,483-491`). Per `ECONOMICS.md` §1 / `SECURITY.md` finding #4 this only affects direct overpayers. |
| **High-value round-0 frivolous dispute** | **NOT mitigated (gap)** | See §1.2 — round 0 has a fee but no slashable bond, so for large deals the break-even confidence to spam a dispute decays toward 0. Addressed by the `[PROPOSAL]` in §1.3, not by shipped code. |
| **Griefing via repeated losing appeals** | **Bounded (shipped)** | `MAX_ROUND = 1` (`src/VerdiktCourt.sol:36`) caps appeals at one; the 10% stake is slashed on an upheld verdict (`src/VerdiktEscrow.sol:258-268`). A second griefing round is structurally impossible. |
| **Dishonest/colluding validators** | **NOT independently mitigated (inherited)** | See §2.1 — validator honesty is inherited from Somnia; Verdikt slashes *operators*, not validators. |
| **Operator front-runs a slash by unbonding** | **Mitigated (shipped)** | `withdrawStake` requires the `withdrawDelay = 7 days` unbonding timer *and* no open challenge (`src/VerdiktMarketplace.sol:88-105`); a challenge filed during unbonding blocks withdrawal until resolved. |
| **Governance/owner is a single key** | **Partially mitigated** | Court ownership is 2-step (`transferOwnership`/`acceptOwnership`, `src/VerdiktCourt.sol:501-515`) and `VerdiktTimelock` ships for parameter governance (per `ECONOMICS.md` §4). But `resolveChallenge` (`src/VerdiktMarketplace.sol:119`) is `onlyOwner` — the marketplace's slash decision is centralized until governance is decentralized. Honest residual risk. |

---

## 4. Economic hardening roadmap (prioritized)

1. **`[PROPOSAL]` Ship the round-0 dispute bond (§1.3).** Highest leverage: it
   closes the only un-bonded entry point and reuses the existing
   `AppealInfo`/`keeperCutBps`/`_credit` machinery, so it is a small, symmetric
   addition rather than new architecture. Suggest `disputeBondBps` 250–500.
2. **Decentralize `resolveChallenge`.** The marketplace slash is `onlyOwner`
   today; route it through `VerdiktTimelock` (already shipped) and, longer term,
   a multisig or a higher-court re-arbitration, so the operator-accountability
   layer is not itself a trusted single key.
3. **Calibrate `perAgentPrice` against measured cost** (the existing Phase-5 TODO
   in `ECONOMICS.md` §3): set the markup to actual keeper-gas + RPC spend per
   case so the operator margin is real and the fee floor that deters spam is
   defensible rather than a flat policy number.
4. **Document the inherited-validator trust assumption prominently** (§2.1) in
   user-facing material — Verdikt's honesty guarantee is Somnia's validator
   security plus byte-identical consensus, *not* an independent crypto-economic
   guarantee at the juror level. Set expectations accordingly.
5. **Revisit panel sizing once the validator set supports panel ≥ 9.** The appeal
   tier's collusion resistance and the live realizability of the 0.72 STT appeal
   fee both depend on it (`ECONOMICS.md` §1 caveat); track it as a mainnet
   deployment prerequisite.

---

*All `[PROPOSAL]` items above are design recommendations and are not present in
the deployed contracts. Everything not so labelled is grounded in the source
files and line ranges cited inline.*
