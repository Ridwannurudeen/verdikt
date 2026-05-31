# Verdikt — Beyond Somnia: A Portable Arbitration Standard

Phase 5 design note. Verdikt's value is a **pattern**, not a chain: *open a dispute → convene
a panel of agents that return a constrained verdict by consensus → settle programmatically,
with a verifiable per-juror receipt → optionally appeal with a stake and a larger panel.*
Only a thin slice of that touches Somnia. This document separates the Somnia-specific surface
from the chain-agnostic core, and proposes the minimal abstraction that makes `VerdiktCourt`
portable to any chain with verifiable agent inference.

Grounded in the deployed code: `src/VerdiktCourt.sol`, `src/interfaces/IAgentRequester.sol`,
`src/interfaces/ILLMAgent.sol`, `src/interfaces/IVerdiktCourt.sol`, `src/VerdiktEscrow.sol`.

---

## 1. What is Somnia-specific vs. chain-agnostic

### Somnia-specific surface (the only coupling)

Everything that ties `VerdiktCourt` to Somnia lives in **four call/data shapes**, all from
`IAgentRequester` / `ILLMAgent`:

| Somnia surface | Where used in `VerdiktCourt` | What it does |
|---|---|---|
| `createAdvancedRequest(agentId, cb, sel, payload, subcommitteeSize, threshold, ConsensusType, timeout)` | `_dispatch` | Dispatch a panel inference request, paying the deposit |
| `ConsensusType.Majority` | `_dispatch` | Asks the platform to enforce byte-identical Majority consensus |
| `getAdvancedRequestDeposit(subcommitteeSize)` | `_depositFor` | Quote the platform's per-request deposit |
| The **callback + receipt model** — `handleVerdict(requestId, Response[], ResponseStatus, Request)`, with `responses[0].result` and `responses[0].receipt` | `handleVerdict` | Deliver the consensus result + a per-juror reasoning receipt |
| `ILLMAgent.inferString.selector` + `allowedValues` payload encoding | `_buildPayload` | Constrain the model to one of `[PAYEE, PAYER, SPLIT]` so Majority is meaningful |
| `agentId`, platform address, `requestTimeout` (seconds) | constructor / state | Somnia agent + platform identity |

That is the **entire** Somnia footprint — and it is *already isolated in interface files*
(`src/interfaces/`) and a handful of call sites. The coupling is shallow by construction.

### Chain-agnostic core (the actual product)

None of the following references Somnia at all:

- **The Court state machine** — `openCase → _dispatch → handleVerdict → appeal → finalize`,
  with `CaseStatus { None, Pending, Ruled, Final, Errored }` and `Verdict { NONE, PAYEE, PAYER,
  SPLIT }`. The escalation (round 0 panel 5 → round 1 panel 9, `MAX_ROUND = 1`), the appeal
  window, permissionless `finalize`, and error/`retry` handling are pure protocol logic.
- **The consumer contract** — `IVerdiktConsumer.onVerdict(escrowRef, verdict)`. Every consumer
  (`VerdiktEscrow`, `VerdiktInsurance`, `VerdiktAgentEscrow`, `VerdiktTokenEscrow`,
  `VerdiktGrantClawback`, `VerdiktMilestone`) only knows this callback — none touch the platform.
- **The appeals + slash layer** — `appealStakeBps`, `keeperCutBps`, slash-on-upheld /
  return-on-overturned. Pure economics.
- **The precedent layer** — `VerdiktRegistry` indexing FINAL rulings, `EvidenceLib` structured
  evidence with `priorCaseId`. Reads `court.getCase`; no platform dependency.

**Conclusion:** the moat (state machine + appeals + precedent + consumer network) is already
chain-agnostic. Only the *inference dispatch + receipt retrieval* binds to Somnia, through a
narrow, already-isolated surface.

---

## 2. The minimal abstraction: `IInferencePlatform` adapter

Today `VerdiktCourt.platform` is typed `IAgentRequester` — the raw Somnia interface. The
portable refactor is to depend on a **small adapter interface** that captures exactly the
three things the Court needs — *quote a deposit*, *dispatch a constrained consensus request*,
*receive a consensus result + receipt* — and nothing Somnia-specific.

### Sketch (illustrative — PROPOSED, not yet in the repo)

```solidity
// PROPOSED — Phase 5 portability layer. Not implemented yet.
interface IInferencePlatform {
    /// @notice Quote the native-token deposit to run a `panelSize` panel.
    function quoteDeposit(uint256 panelSize) external view returns (uint256);

    /// @notice Dispatch a panel that must agree (by majority, byte-identically) on
    /// exactly one of `allowedOutputs`. The adapter encodes the platform-specific
    /// payload and consensus settings internally.
    function dispatch(
        bytes calldata prompt,
        string[] calldata allowedOutputs,
        uint256 panelSize,
        address callback,
        bytes4 callbackSelector
    ) external payable returns (uint256 requestId);
}

/// @notice What the Court's callback must accept — generalized from Somnia's structs.
interface IInferenceConsumer {
    function onInference(
        uint256 requestId,
        string calldata result,   // the agreed output (one of allowedOutputs), or empty on failure
        uint256 receiptId,        // per-juror reasoning receipt handle (0 if none)
        bool success
    ) external;
}
```

`VerdiktCourt` would then type `platform` as `IInferencePlatform`, replace `_depositFor` with
`platform.quoteDeposit(panel) + perAgentPrice * panel`, replace the `createAdvancedRequest`
block with `platform.dispatch{value:}(...)`, and flatten `handleVerdict` to `onInference(...)`.
A **`SomniaInferenceAdapter`** then implements `IInferencePlatform` by wrapping today's logic
verbatim (threshold = `panel/2+1`, `ConsensusType.Majority`, `inferString(allowedValues)`,
decode `Response[]`/`receipt`). **No core logic changes** — the Somnia specifics move into the
adapter, where they belong.

**Scope (honest accounting):** this is a breaking refactor of `VerdiktCourt` (constructor type,
dispatch, callback) but it does **not** touch any consumer — `IVerdiktConsumer.onVerdict` is
unchanged, so all six consumers, the appeals/slash layer, the registry, and `EvidenceLib` are
untouched. Blast radius: one contract plus a new adapter. *(Speculative: exact test churn not
estimated; the existing platform mock becomes a mock adapter.)*

---

## 3. What each target chain must provide (portability checklist)

| Requirement | Why Verdikt needs it | Somnia's answer |
|---|---|---|
| On-chain dispatch of an agent/LLM request, paid in native value | Convene panels autonomously from a contract | `createAdvancedRequest{value:}` |
| Multi-node execution with on-chain consensus over a *constrained* output set | Byte-identical Majority over `[PAYEE,PAYER,SPLIT]` is what makes the verdict trust-minimized | `ConsensusType.Majority` + `inferString(allowedValues)` |
| A deterministic deposit quote | `quoteOpen`/`quoteAppeal` price the case before dispatch | `getAdvancedRequestDeposit(panelSize)` |
| A contract callback delivering the agreed result | Settlement is programmatic (`onVerdict`) | `handleResponse(requestId, Response[], status, ...)` |
| A verifiable per-juror receipt | Auditable reasoning is the trust story (precedent layer cites `receiptId`) | `Response.receipt` |
| A failure/timeout signal | The `Errored`/`retry` path needs it | `ResponseStatus { Failed, TimedOut }` |
| A sufficiently large validator/agent set | Panel sizes (5, 9) require ≥ panel nodes | *Shannon's effective cap is ~6, so panel-9 reverts live today (ROADMAP Phase 2). Any target chain must meet the max panel size.* |

A chain with **all seven** can host Verdikt by writing only an adapter. Candidate substrates
(speculative — not verified against current docs, listed for direction only): verifiable-
inference / ZK-or-optimistic ML-inference oracles (the proof plays the receipt's role);
decentralized oracle networks with off-chain compute + on-chain aggregation over a constrained
answer set; other agentic L1s/L2s exposing an on-chain agent-request primitive.

> These are **speculative**: the signatures and consensus guarantees above are verified only
> for Somnia. Porting to a specific substrate requires confirming it provides the seven
> properties — especially the two hard ones: **(a) on-chain consensus over a constrained output
> set** and **(b) a verifiable per-juror receipt.** A substrate missing either runs Verdikt only
> in a trust-degraded mode (single-node verdict, or no auditable reasoning), defeating the premise.

---

## 4. Summary

- **~95% of Verdikt is already portable.** The state machine, appeals/slash economics,
  precedent layer, and all six consumers are chain-agnostic and depend only on
  `IVerdiktConsumer.onVerdict`.
- **The Somnia coupling is four call/data shapes** in one contract, already isolated in
  `src/interfaces/`.
- **The minimal abstraction is one adapter interface** (`IInferencePlatform` +
  `IInferenceConsumer`) so `VerdiktCourt` depends on the adapter, not Somnia. A
  `SomniaInferenceAdapter` wraps today's behavior verbatim; new chains write a new adapter.
- **A target chain qualifies** if it provides the seven-item checklist — the load-bearing two
  being on-chain consensus over a constrained output set and a verifiable per-juror receipt.
- **Status:** the adapter interface is *proposed, not implemented*. Everything attributed to
  current code is grounded in the cited files; everything about non-Somnia substrates is
  marked speculative.
