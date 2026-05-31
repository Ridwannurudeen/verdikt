# Verdikt — Economic Design

Phase 5 design note. Grounds every number in the deployed contracts:
`src/VerdiktCourt.sol`, `src/VerdiktEscrow.sol`, and the Somnia platform surface in
`src/interfaces/IAgentRequester.sol` / `ILLMAgent.sol`. Court fees are denominated in
STT (Somnia's native gas/stake token on Shannon, chain 50312). Where a figure depends on
the platform's `getAdvancedRequestDeposit` (an on-chain value we read at runtime, not a
constant), it is marked as such.

---

## 1. Fee model

### Who pays, and for what

There are **two independent money flows**, and keeping them separate is the core of the design:

1. **Court fees** — what it costs to convene an AI panel. Paid in STT, forwarded to the
   Somnia platform via `createAdvancedRequest{value: deposit}`, and consumed by validator
   inference. This is a *cost of service*, not value at stake.
2. **Escrowed value** — the deal amount and any appeal stake. Held by the consumer
   (`VerdiktEscrow`), never sent to the court. The court only returns a *verdict label*;
   the consumer moves the money.

The court never custodies the disputed value. `VerdiktCourt` holds only the agent-fee STT
(plus any platform rebate dust, swept by the owner via `sweep`). This separation is why one
Court can serve many consumers (Phase 4: 6 consumers on one Court) without ever touching
their balances.

### The disputing party funds the panel

The party that opens a dispute pays the panel fee. In `VerdiktEscrow.dispute`:

```solidity
uint256 fee = court.quoteOpen();
require(msg.value >= fee, "fee too low");
...
uint256 caseId = court.openCase{value: fee}(dealId, evidence);
_refundExcess(msg.value, fee);
```

So the disputer pre-funds exactly `quoteOpen()` and gets any overpayment refunded at the
consumer boundary. (Direct callers of `Court.openCase` are *not* refunded — see SECURITY.md
finding #4; consumers forward the exact fee, so this affects only direct overpayers.)

### How the fee scales with panel size

The fee is computed in `_depositFor`:

```solidity
function _depositFor(uint256 panel) internal view returns (uint256) {
    return platform.getAdvancedRequestDeposit(panel) + perAgentPrice * panel;
}
```

with `perAgentPrice = 0.07 ether` and panel sizes from `_panelSize`: **round 0 (trial) = 5
agents**, **round 1 (appeal) = 9 agents**, `MAX_ROUND = 1`.

The fee has two components:

| Component | What it is | Scales with |
|---|---|---|
| `getAdvancedRequestDeposit(panel)` | Platform's raw inference deposit | panel size, set by Somnia |
| `perAgentPrice * panel` | Verdikt's per-agent markup (0.07 STT each) | panel size, linearly |

The README states the all-in totals (verified live: the Phase 0 determinism gate fired a
panel-5 request at **fee 0.40 STT**, requestId 3486438):

| Round | Panel | Inference fee component (`0.07 × panel`) | All-in fee |
|---|---|---|---|
| 0 (trial) | 5 | 0.35 STT | **≈ 0.40 STT** |
| 1 (appeal) | 9 | 0.63 STT | **≈ 0.72 STT** |

The implied `getAdvancedRequestDeposit` contribution is therefore ≈ 0.05 STT at panel 5 and
≈ 0.09 STT at panel 9 (≈ 0.01 STT/agent). These are inferred from the README's published
totals minus the known `0.07 × panel` markup; the exact platform deposit is read on-chain at
runtime and may move — `quoteOpen()` / `quoteAppeal()` always return the live value, so
consumers never hardcode it.

> **Operational caveat (verified, ROADMAP Phase 2):** Shannon's validator subcommittee
> effective cap is ~6 (docs ceiling 10), so the panel-9 appeal *reverts live on Shannon
> today*. The appeal economics below are exact in the contract and unit-tested, but the live
> 9-agent fee (0.72 STT) is only realizable on a validator set ≥ 9. On mainnet this is a
> deployment prerequisite, not a redesign.

---

## 2. Anti-frivolous-appeal analysis

Only the **losing** party can appeal a decisive verdict (`VerdiktEscrow.appeal`:
`require(msg.sender == loser, "only losing party")`; for SPLIT, either party may). The appeal
re-tries the case with **new evidence** under a larger panel (5 → 9). Two things gate the
appellant:

```solidity
uint256 stake = (d.amount * appealStakeBps) / 10000;   // 10% of the deal
uint256 agentDep = court.quoteAppeal(d.caseId);         // ≈ 0.72 STT (panel 9)
require(msg.value >= stake + agentDep, "value too low");
```

with `appealStakeBps = 1000` (10%) and `keeperCutBps = 500` (5%).

### Outcome accounting (from `onVerdict`)

Let the deal amount be `A`. Stake `S = 0.10·A`. Appeal panel fee `f ≈ 0.72 STT`.

- **Appeal fails (verdict == preAppealVerdict, i.e. upheld):** the stake is slashed.
  Treasury cut `c = S · keeperCutBps/10000 = 0.05·S = 0.005·A`. The counterparty (winner)
  receives `S − c = 0.095·A`. The appellant also loses the panel fee `f` (non-refundable;
  it was consumed by inference). **Appellant net loss = S + f = 0.10·A + 0.72 STT.**
- **Appeal succeeds (verdict overturned):** the stake `S` is returned in full. The panel fee
  `f` is still spent. **Appellant net loss = f = 0.72 STT**, but they now win the deal instead
  of losing it (swing = `A`, or `A/2` if the new verdict is SPLIT).

### Expected-cost / break-even

Let `p` = the appellant's *belief* that the appeal flips the verdict in their favor. If they
accept the loss, they get **0** of the deal. If they appeal:

```
E[gain from appealing] = p · A                         (recover the deal on a flip)
E[cost of appealing]   = f  +  (1 − p) · S             (fee always; stake only if upheld)
```

Appealing is rational when expected gain exceeds expected cost:

```
p · A  >  f + (1 − p) · S
p · (A + S)  >  f + S
```

**Break-even belief:**

```
        f + S            0.72 STT + 0.10·A
p*  =  ─────────  =  ─────────────────────────
        A + S               1.10·A
```

#### Worked numbers (`f = 0.72 STT`, `S = 0.10·A`)

| Deal amount `A` | Stake `S` (10%) | `p*` (break-even belief the verdict flips) |
|---|---|---|
| 1 STT | 0.10 STT | **0.745** (74.5%) |
| 5 STT | 0.50 STT | **0.222** (22.2%) |
| 10 STT | 1.0 STT | **0.156** (15.6%) |
| 100 STT | 10 STT | **0.0975** (9.75%) |
| → ∞ | 0.10·A | → S/(A+S) = **0.0909** (9.1%) asymptote |

As the deal gets large the fixed fee becomes negligible and the break-even converges to
`S/(A+S) ≈ 9.1%`. For small deals the panel fee dominates. This is the intended shape: **the
stake deters frivolous large-value appeals; the fee deters spammy small-value appeals.** A
party with strong new evidence (high `p`) appeals; a party stalling (low `p`) is priced out.

On an upheld appeal the slashed stake is split **95% to the counterparty, 5% to the
treasury**. The 95%-to-winner share compensates the honest party for delay and re-litigation;
the 5% treasury cut funds the operator without making slashing a profit center.

> The stake is denominated in the deal asset (native STT in `VerdiktEscrow`, ERC-20 in
> `VerdiktTokenEscrow`), while the panel fee `f` is always native STT. The analysis above
> assumes an STT deal for a single-unit comparison.

---

## 3. Treasury-cut calibration & a sustainable operator fee model

`getAdvancedRequestDeposit(panel)` is the platform's raw inference cost (passes through to
validators). `perAgentPrice = 0.07 STT/agent` is **Verdikt's markup** — the only revenue the
court operator earns per case, accrued as the difference between what consumers pay and what
the platform consumes, collected via `sweep`.

| Round | Panel | Operator markup (`0.07 × panel`) |
|---|---|---|
| Trial | 5 | 0.35 STT |
| Appeal | 9 | 0.63 STT |

The markup is `setPerAgentPrice`-adjustable, so the operator can calibrate margin to cover
keeper gas, RPC/indexer infra, and a platform-deposit volatility buffer. **Phase-5 TODO:**
calibrate `perAgentPrice` against measured keeper-gas + RPC spend per case (today 0.07 is a
flat policy number).

Two revenue streams, deliberately asymmetric:

| Stream | Source | Magnitude | Intent |
|---|---|---|---|
| **Markup** (`perAgentPrice`) | Every case/panel | 0.35–0.63 STT/case | Covers cost of running the court |
| **Treasury cut** (`keeperCutBps`) | Only *upheld* appeals | 0.5% of deal | Small, so slashing isn't a profit motive |

**Recommendation:** keep `keeperCutBps` ≤ a few hundred bps; treat the markup, not the cut, as
the operator's real margin. Raising the cut toward the counterparty's share would invert the
incentive (operator benefits from upheld appeals) and erode the "95% compensates the honest
party" guarantee.

---

## 4. Why a governance token is NOT warranted yet

Per the project's no-speculative-generality rule (a token earns its place "only if it earns
its place"), **Verdikt should not issue a governance token now.**

The system already functions without one: **fees** price the service, **stakes** secure
honesty, **consensus** (the validator subcommittee, paid in STT) secures truth, and
**parameters** are owner-set today with a clear migration to a **timelock/multisig**
(`VerdiktTimelock`, shipped this phase). A token would add speculative surface without a
coordination need — no staking role for holders (validators stake on the platform, not on
Verdikt), no emissions problem, no contended treasury at this scale.

A token becomes justified only when a **real coordination problem** appears that fees + a
multisig cannot solve — concretely, when any of these is *live* (not anticipated):

1. **Decentralized parameter governance at scale** — many independent consumers/operators
   need sybil-resistant, skin-in-the-game voting rather than a multisig.
2. **The arbitration marketplace** — competing court configs need curation, slashing of bad
   configs, and fee-routing; a staked token to back/curate configs would have a concrete job.
3. **Operator/keeper bonding** — a permissionless keeper/operator set bonded against
   misbehavior (downtime, censorship). The 5% treasury cut is the seed; STT suffices until the
   set is large and adversarial.
4. **Sybil-resistant reputation** — bonding a party's litigation record to a staked token to
   make it costly to fake.

Until one is live, the answer is **no token**: govern with multisig→timelock over the existing
parameters, and revisit only when a coordination need actually materializes.
