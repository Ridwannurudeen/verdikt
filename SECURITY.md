# Verdikt — Security Notes

Internal audit of `VerdiktCourt`, `VerdiktEscrow`, `VerdiktInsurance`, `VerdiktAgentEscrow`
(2026-05-31). Unaudited hackathon code on Shannon testnet — this records the known issues, what
is already addressed, and the remediation plan for a production (v2) deploy.

## Trust model

The Somnia Agents platform is trusted to (a) enforce `ConsensusType.Majority` so `responses[0]`
is the agreed value, and (b) only call `handleVerdict` from the platform address. The Court owner
is trusted for parameter setting (`setAgentId`/`setPerAgentPrice`/`setAppealWindow`/`setRequestTimeout`/`sweep`).

## Findings

| # | Severity | Issue | Status |
|---|----------|-------|--------|
| 1 | HIGH | **Push-payment bricking.** `VerdiktEscrow`/`VerdiktInsurance` settle inside `onVerdict` via `_pay` (`.call` + `require(ok)`). A winning recipient that reverts on receipt reverts `onVerdict` → reverts `finalize`, permanently stranding the disputed funds. No pull fallback, no admin rescue. | **Fix shipped as the reference pattern** in `VerdiktAgentEscrow` (pull-payment `pending[]` ledger + `withdraw()`); v2 ports it to Escrow/Insurance. v1 contracts are EOA-oriented (mitigates likelihood). |
| 2 | HIGH | **Reentrancy.** No reentrancy guards anywhere. `finalize`→`onVerdict` pushes ETH while `VerdiktInsurance` global pool accounting (`totalPool`) is mid-update; a reentrant `fundPool`/`appealClaim` sees an inconsistent share price. | v2: adopt pull-payment (removes the push from `onVerdict`) + add a `nonReentrant` guard on settlement/withdraw paths. `VerdiktAgentEscrow.withdraw` is already CEI-correct. |
| 3 | MEDIUM | **Appeal-window retro-shrink.** `appeal`/`finalize` read the live `appealWindow`; the owner can `setAppealWindow(small)` then `finalize` in the same block to deny a pending honest appeal. | v2: snapshot `c.appealDeadline = rulingTime + appealWindow` in `handleVerdict`; check against the snapshot so window changes apply only to future rulings. |
| 4 | MEDIUM | **`Court.sweep` captures overpayment.** `openCase` requires `msg.value >= quoteOpen()` but never refunds excess; `sweep` sends it to the owner. (Consumers forward exact `fee`, so only direct `openCase` overpayers are affected.) | v2: refund excess in `openCase`/`appeal`/`retry`. |
| 5 | MEDIUM | **Insurance micro-funder griefing.** Any address with ≥1 wei of pool shares can file the pool's one-shot appeal, delaying every winning claim. | v2: require a minimum-share threshold to file a pool-side appeal. |
| 6 | LOW | `handleVerdict` trusts `responses[0]` as canonical (relies on platform Majority enforcement). | Within trust model. Documented. |
| 7 | LOW | Fee re-quote across the consumer→court boundary — verified safe; refund logic correct (`_refundExcess`). | No action. |
| 8 | INFO | `VerdiktAgentEscrow` pull-ledger conservation holds; no on-chain `Σ pending ≤ balance` assertion. | Covered by invariant tests. |
| 9 | INFO | `NONE` verdict is unreachable in consumers (converted to `Errored` in `handleVerdict`); SPLIT + double-settle handled correctly. | Confirmed correct. |
| 10 | INFO | `VerdiktAgentEscrow.withdraw` CEI correct; front-running not exploitable. | Confirmed correct. |

## Addressed this pass

- **`VerdiktAgentEscrow`** is the pull-payment reference implementation that remediates #1/#2 — settlement credits a `pending[]` ledger and each party pulls via `withdraw()`, so a reverting counterparty can never brick settlement or the court callback. Proven in `test/AgentToAgentDemo.t.sol::test_revertingCounterparty_cannotBrickSettlement`.
- **Invariant + fuzz tests** (`test/Invariant.t.sol`): fund conservation, solvency, stake-slash exactness (`toWinner + treasuryCut == stake`), `_split` payout sums, and no-double-settle.
- **`evm_version` confirmed** — Shannon supports Cancun (verified on-chain); bumped from `paris`.

## v2 remediation priority

1. Port the `VerdiktAgentEscrow` pull-payment pattern into `VerdiktEscrow` and `VerdiktInsurance`; add `nonReentrant` to settlement/withdraw. (Closes #1 + #2 together.)
2. Snapshot the appeal deadline per case. (#3)
3. Refund `openCase` overpayment. (#4)
4. Minimum-share threshold for pool appeals. (#5)
