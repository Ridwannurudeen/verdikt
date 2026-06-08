# Verdikt — Audit Readiness Packet

A scoping packet for a third-party auditor. It summarizes the architecture, trust boundaries,
in-scope contracts, known/accepted risks, the invariants the system must hold, test coverage,
and how to build and reproduce. Pair it with [`SECURITY.md`](SECURITY.md) (internal review, 20
findings, all marked Fixed) and [`deployments/shannon.json`](deployments/shannon.json) (live
addresses + live gate results).

- **Language / toolchain:** Solidity `^0.8.20`, compiled `solc 0.8.24`, `evm_version = cancun`,
  Foundry. No OpenZeppelin — primitives are in-repo.
- **Network today:** Somnia Shannon testnet (chain 50312). Mainnet is chain 5031 (see
  [`MAINNET-RUNBOOK.md`](MAINNET-RUNBOOK.md)).
- **Status:** internal review only; **no external audit yet**. This packet is to commission one.

---

## Architecture summary

One reusable arbitration primitive (`VerdiktCourt`) plus many independent consumers that settle
on it. The Court is the only contract that talks to the Somnia Agents platform.

```
Consumer (e.g. VerdiktEscrow)        VerdiktCourt (arbitration primitive)         Somnia Agents
  createDeal / release                openCase ─┐                                   (validator
  dispute  ──────────────────────────▶ appeal   ├─▶ createAdvancedRequest ────────▶  subcommittee
  appeal (stake)                       finalize ─┘     (panel N, Majority M-of-N)       runs LLM)
  onVerdict ◀── settle + slash ◀────── handleVerdict ◀── consensus result + receiptId ◀─
```

- A consumer opens a case with evidence; the Court convenes a panel via `createAdvancedRequest`
  with a **fixed allowed-values set** (`PAYEE/PAYER/SPLIT`, or graded
  `PAYER/SPLIT25/SPLIT50/SPLIT75/PAYEE`, plus optional `UNDECIDABLE`) so outputs are
  byte-identical and Majority consensus is meaningful.
- `handleVerdict` decodes the consensus verdict, opens an appeal window (snapshotted deadline),
  supports one staked appeal re-tried by a larger panel, then `finalize` settles and the
  consumer's `onVerdict` runs.
- **Settlement is pull-payment everywhere** (`pending[]` ledgers + `withdraw()`), so a reverting
  recipient can never brick finalization.
- The trial panel is **caller-selectable in `[MIN_TRIAL_PANEL=3, 5]`** so a dispute degrades
  gracefully when Somnia's validator set dips below full strength (avoids platform revert
  `0x8f4079ff`).

**Hardening surface on the Court** (all live in the June 7 premium stack): governed/versioned immutable prompt with
per-case version snapshot; an attestation-registry hook folding VERIFIED facts in as
authoritative; opt-in abstention (`UNDECIDABLE`); graded splits; injection-resistant
sanitized+fenced evidence; 2-step ownership.

---

## Trust boundaries

| Boundary | Trusted? | Notes |
| --- | --- | --- |
| Somnia Agents platform (`IAgentRequester`) | **Trusted** | Enforces `ConsensusType.Majority`, so `responses[0]` is the agreed value; only the platform address may call `handleVerdict`. Out of Verdikt's control (finding #10). |
| LLM-inference agent output | **Trusted to be deterministic** | The whole design rests on byte-identical convergence — validated live (`determinismGate`/`gradedDeterminismGate`/`abstentionGate`), not proven. |
| Court owner / timelock | **Trusted, bounded** | Parameter setters (`setAgentId`, pricing, `setAppealWindow`, `setRequestTimeout`, prompt publish/activate, attestation wiring, abstention toggle, `sweep`). Prompt is governed + timelocked + cited per case; a malicious governor is mitigated, not eliminated. |
| Attestors (attestation registry) | **Trusted, governed** | Posted facts are authoritative and **not** sanitized; trust = governance over the attestor set. |
| Dispute parties / evidence | **Untrusted** | Evidence is sanitized + fenced + marked untrusted in the prompt. |
| Consumers / keepers / appellants | **Untrusted** | Permissionless; guarded by status checks, stakes, and pull payments. |

---

## In-scope contracts (one line each)

Production `src/` (+ shared library). Read each file's header for the full description.

- **`src/VerdiktCourt.sol`** — reusable AI-jury engine: panel request, consensus decode, appeal
  window + escalation, finalize, governed prompt, attestation hook, 2-step ownership.
- **`src/VerdiktConsumerBase.sol`** — inherit-and-go base: dispute open (quote/fee/refund),
  caseId↔ref mapping, verdict (graded + `UNDECIDABLE`) → payee basis-point share.
- **`src/VerdiktEscrow.sol`** — two-party escrow with stake-backed appeals and two-sided
  evidence; pull-payment settlement.
- **`src/VerdiktAgentEscrow.sol`** — machine-native escrow where both counterparties may be
  contracts; pull payments so a non-receiving agent can't brick the callback.
- **`src/VerdiktTokenEscrow.sol`** — ERC-20-denominated escrow (court fees stay native STT);
  rejects fee-on-transfer underfunding.
- **`src/VerdiktInsurance.sol`** — collateralized claims-arbitration pool with pro-rata shares,
  coverage locks, and staked appeals.
- **`src/VerdiktGrantClawback.sol`** — DAO grant escrow: PAYER = clawback to DAO, PAYEE =
  release to grantee.
- **`src/VerdiktMilestone.sol`** — freelance milestone escrow: PAYEE = pay freelancer, PAYER =
  refund client.
- **`src/VerdiktRegistry.sol`** — permissionless, append-only index of FINAL rulings (machine
  case law; the target of `EvidenceLib.priorCaseId`).
- **`src/VerdiktReputation.sol`** — per-party litigation record/score; verdict read from the
  Court, `side` caller-asserted (known simplification).
- **`src/VerdiktAttestationRegistry.sol`** — governed trusted-attestor registry of VERIFIED,
  append-only, deterministically-rendered facts.
- **`src/VerdiktCourtRegistry.sol`** — court discovery; `cheapest()` shops by live `quoteOpen`
  and SLA, skipping listings whose quote reverts.
- **`src/VerdiktMarketplace.sol`** — court economics: operators stake, anyone challenges a
  ruling for a bond, governance slashes on upheld; `bestCourt()` routes by quality.
- **`src/VerdiktKeeperBounty.sol`** — permissionless liveness market: fund a bounty,
  `finalizeAndClaim` settles and takes the pot; funders can `reclaim` until claimed.
- **`src/VerdiktTimelock.sol`** — generic delayed-execution governor that can own the Court.
- **`src/lib/EvidenceLib.sol`** — deterministic structured-evidence formatter (byte-identical
  input for the panel).

Interfaces (`src/interfaces/*.sol`) are definitions only. Examples (`src/examples/SimpleEscrow.sol`,
`src/examples/VerdiktPredictionMarket.sol`) and `test/mocks/*` are teaching/test code — **not**
production-audited; review for reference, not for production sign-off.

---

## Known issues / accepted risks

From the internal review (`SECURITY.md`). All 20 findings are marked **Fixed**; the standing
accepted-risk set is:

- `handleVerdict` trusts `responses[0]` as canonical — within the platform-Majority trust model
  (finding #10, INFO).
- Prompt governance: a malicious governor could publish a biased prompt — mitigated by the
  timelock (transparent + delayed) and per-case prompt-version citation.
- Attestation facts are trusted and **not** sanitized — a compromised attestor could post a
  misleading fact; trust = governance over the attestor set.
- `VerdiktReputation` takes a caller-asserted `side` (verdict itself is authoritative) — known
  simplification; a production module would source parties from the consumer.
- Agent-fee rebates accrue to the Court (owner `sweep`), not per-request refunds.

**Remaining production work** (from `SECURITY.md`): external audit + bug bounty before mainnet;
consumer-sourced reputation; redeploy the extra consumers
(AgentEscrow/TokenEscrow/GrantClawback/Milestone/Insurance are built but not all redeployed with the full
premium surface). Re-run the determinism gates after any prompt or label-set change.

---

## Invariants

Codified in [`test/Invariant.t.sol`](test/Invariant.t.sol) — a stateful handler drives
`VerdiktEscrow` through `create → dispute → verdict → appeal → finalize` over randomized
interleavings, plus targeted fuzz/unit conservation tests:

1. **Fund conservation** — payouts never exceed inflows:
   `totalPaidOut ≤ totalFunded + totalStaked` (`invariant_payoutsNeverExceedInflows`).
2. **Solvency** — escrow balance always backs outstanding obligations:
   `address(escrow).balance ≥ outstanding` (`invariant_solvency`).
3. **Exact accounting** — `outstanding == totalFunded + totalStaked − totalPaidOut`, so no value
   is silently created or destroyed (`invariant_outstandingAccounting`).
4. **Payout sums to the deal amount** for every verdict — PAYEE → full to payee, PAYER → full
   refund, SPLIT → halves with the remainder wei routed to the payee
   (`testFuzz_split_*`).
5. **Stake-slash exactness** — on an upheld appeal, `toWinner + treasuryCut == stake`; on an
   overturned appeal the whole stake is returned with no treasury cut
   (`testFuzz_appealUpheld_stakeSplitConserved`, `testFuzz_appealOverturned_stakeReturnedWhole`).
6. **No double-settle / double-finalize** — a finalized case can't be re-finalized, a settled
   deal can't be re-released/re-disputed, and a stale `onVerdict` callback is rejected
   (`test_noDoubleFinalize`, `test_noDoubleSettle_dealStaysSettled`,
   `test_settledDeal_rejectsStaleVerdictCallback`).

Auditors should consider extending invariant coverage to the other consumers (insurance pool
solvency under coverage locks, token-escrow balance conservation, marketplace stake/slash
conservation), which are currently covered by per-contract unit/fuzz tests rather than the
stateful invariant runner.

---

## Test coverage

- **Documented suite: `forge test` passes 230/230**, including fuzz and invariant tests
  (`SECURITY.md` line 40; `README.md`). Coverage spans non-receiving settlement recipients,
  appeal-deadline snapshots, insurance capacity locks, pro-rata share minting, micro-funder
  appeal rejection, registry quote-revert skipping, no-return + fee-on-transfer ERC-20s, graded
  split settlement, split-bps appeal changes, pull-refunds, and prompt-injection fencing.
- 25 `test/*.sol` files (per-contract suites + `Invariant.t.sol` + `PromptInjection.t.sol` /
  `PromptGovernance.t.sol` / `Attestation.t.sol` / `Abstention.t.sol` / `GradedSplit.t.sol` /
  `Marketplace.t.sol` / `KeeperBounty.t.sol` / `AgentToAgentDemo.t.sol` / `ServiceSLA.t.sol` /
  `ModelVersion.t.sol`).
- **Reproduce the live number with `forge test`**. A static grep of `test*` / `testFuzz*` /
  `invariant*` function declarations also returns 230, matching the Foundry run.

---

## Static analysis

The repo now carries `.solhint.json`; the lint command runs without a missing-config blocker.

```bash
npx solhint "src/**/*.sol" "test/**/*.sol" "script/**/*.sol"   # 0 errors; style/pattern warnings remain
python -m slither . --filter-paths "lib|test|script|out|cache" # completed; 78 reviewed findings
```

The Slither hardening pass fixed the actionable findings by adding reentrancy guards around
court/platform, token, callback, and withdrawal boundaries; moving refund/bookkeeping before
external calls where the fee is already known; rejecting zero-address keeper-bounty courts; and
adding governance parameter events. Remaining Slither output is reviewed residual risk/design
surface: pull-payment/native bounty sends, deadline timestamp comparisons, token balance-delta
equality used to reject fee-on-transfer tokens, request-id mappings that must be written after the
Somnia platform returns, and live quote calls inside bounded registry/marketplace scans.

---

## Build, test, reproduce

```bash
forge build
forge test            # 230/230 (solc 0.8.24, evm_version cancun)
forge test --gas-report
forge coverage        # optional, for line/branch coverage
```

**Live-behavior reproduction** (needs a Shannon-funded `PRIVATE_KEY` and a real `LLM_AGENT_ID`
from agents.somnia.network in `.env`):

```bash
# determinism gate
forge script script/Probe.s.sol:ProbeDeploy --rpc-url shannon --broadcast
cd script && npm install && node run-determinism-gate.mjs <PROBE_ADDR>
# accuracy benchmark
node run-benchmark.mjs        # dataset: script/benchmark-cases.json
```

Live gate results (determinism / graded determinism / abstention / injection / accuracy
11-of-12) and all deployed addresses are recorded in `deployments/shannon.json`.
