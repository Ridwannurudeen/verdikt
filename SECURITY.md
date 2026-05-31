# Verdikt - Security Notes

Internal audit of `VerdiktCourt`, `VerdiktEscrow`, `VerdiktInsurance`, `VerdiktAgentEscrow`,
`VerdiktTokenEscrow`, and the support tooling (2026-05-31). Unaudited hackathon code on
Somnia Shannon testnet.

## Trust Model

The Somnia Agents platform is trusted to enforce `ConsensusType.Majority` so `responses[0]`
is the agreed value, and to only call `handleVerdict` from the platform address. The Court
owner is trusted for parameter setting (`setAgentId`, `setPerAgentPrice`, `setAppealWindow`,
`setRequestTimeout`, `sweep`).

## Findings

| #   | Severity | Issue                                                                                                                                                                        | Status                                                                                                                                                                                 |
| --- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | HIGH     | Push-payment bricking in native Escrow/Insurance settlement. A recipient that reverts on ETH receipt could revert `onVerdict`, revert `finalize`, and strand disputed funds. | Fixed. `VerdiktEscrow`, `VerdiktInsurance`, and `VerdiktAgentEscrow` now settle through `pending[]` pull-payment ledgers.                                                              |
| 2   | HIGH     | Insurance pool under-collateralization. Funders could withdraw collateral backing active policies, and policies could be sold beyond free pool capacity.                     | Fixed. `lockedCoverage` tracks active exposure; policy creation checks free capacity; pool withdrawals cannot remove locked coverage; `expirePolicy` releases expired unused coverage. |
| 3   | HIGH     | Incorrect insurance share minting. New funders received 1:1 shares even after premiums/slashed stakes changed share price, letting them capture prior pool value.            | Fixed. `fundPool` mints pro-rata shares from the pre-deposit pool/share ratio.                                                                                                         |
| 4   | MEDIUM   | Appeal-window retro-shrink. `appeal`/`finalize` previously read the live `appealWindow`, so an owner could shorten a pending ruled case's window.                            | Fixed. `VerdiktCourt` snapshots `appealDeadline` when a ruling arrives.                                                                                                                |
| 5   | MEDIUM   | Court direct overpayment capture. Direct `openCase`/`appeal`/`retry` callers could overpay and leave excess sweepable by the owner.                                          | Fixed. The Court refunds excess value after dispatch.                                                                                                                                  |
| 6   | MEDIUM   | Insurance micro-funder griefing. Any tiny pool share could file the pool-side appeal.                                                                                        | Fixed. Pool-side appeals require `poolAppealMinSharesBps` of total shares (default 1%).                                                                                                |
| 7   | MEDIUM   | Court registry availability DoS. One active listed court whose `quoteOpen()` reverted could make `cheapest()` revert for everyone.                                           | Fixed. Registration verifies `quoteOpen`; `cheapest()` skips active listings whose quote reverts.                                                                                      |
| 8   | LOW      | ERC-20 compatibility. Token escrow assumed ERC-20 transfers always return `bool`, excluding no-return tokens.                                                                | Fixed. Token transfer helpers accept either no return data or `true`.                                                                                                                  |
| 9   | LOW      | Frontend/deploy hardening. Static deploy docs used the nginx auto-edit certbot flow, and nginx headers lacked a CSP/frame guard.                                             | Fixed. Deploy docs use `certbot certonly --webroot`; nginx config now includes CSP and `X-Frame-Options`.                                                                              |
| 10  | INFO     | `handleVerdict` trusts `responses[0]` as canonical.                                                                                                                          | Within trust model; relies on Somnia platform Majority enforcement.                                                                                                                    |

## Verification

- `forge test` passes 141/141, including fuzz and invariant tests.
- Regression coverage includes non-receiving settlement recipients, appeal-deadline snapshots,
  insurance capacity locks, pro-rata share minting, micro-funder appeal rejection, registry
  quote-revert skipping, and no-return ERC-20 transfers.
- `node --check` passes for keeper, indexer, and determinism driver.
- `npm audit --audit-level=high` reports 0 vulnerabilities for keeper, script, and indexer.

## Remaining Production Work

- Redeploy the hardened contracts on Shannon before recording the final demo. The current
  addresses in `deployments/shannon.json` are the original live demo deployment.
- Run an external audit before mainnet.
- Replace caller-asserted `VerdiktReputation.record(... side ...)` with consumer-sourced party
  data in a production reputation module.
