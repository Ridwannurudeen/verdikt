# Verdikt - Security Notes

Internal audit of `VerdiktCourt`, `VerdiktEscrow`, `VerdiktInsurance`, `VerdiktAgentEscrow`,
`VerdiktTokenEscrow`, `VerdiktConsumerBase`, and the support tooling (updated 2026-06-02). Unaudited hackathon code on
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
| 5   | MEDIUM   | Court direct overpayment capture/bricking. Direct `openCase`/`appeal`/`retry` callers could overpay; push refunds could also let a non-receiving caller revert its own request. | Fixed. Excess value is credited to `pendingRefunds` and withdrawn with `withdrawRefund`; `sweep` excludes reserved refunds.                                                              |
| 6   | MEDIUM   | Insurance micro-funder griefing. Any tiny pool share could file the pool-side appeal.                                                                                        | Fixed. Pool-side appeals require `poolAppealMinSharesBps` of total shares (default 1%).                                                                                                |
| 7   | MEDIUM   | Court registry availability DoS. One active listed court whose `quoteOpen()` reverted could make `cheapest()` revert for everyone.                                           | Fixed. Registration verifies `quoteOpen`; `cheapest()` skips active listings whose quote reverts.                                                                                      |
| 8   | LOW      | ERC-20 compatibility. Token escrow assumed ERC-20 transfers always return `bool`, excluding no-return tokens.                                                                | Fixed. Token transfer helpers accept either no return data or `true`.                                                                                                                  |
| 9   | LOW      | Frontend/deploy hardening. Static deploy docs used the nginx auto-edit certbot flow, and nginx headers lacked a CSP/frame guard.                                             | Fixed. Deploy docs use `certbot certonly --webroot`; nginx config now includes CSP and `X-Frame-Options`.                                                                              |
| 10  | INFO     | `handleVerdict` trusts `responses[0]` as canonical.                                                                                                                          | Within trust model; relies on Somnia platform Majority enforcement.                                                                                                                    |
| 11  | MEDIUM   | Graded `SPLIT` propagation gap. Several consumers treated every `SPLIT` as 50/50 even when the Court stored `splitBps`.                                                     | Fixed. Agent escrow, token escrow, insurance, grant clawback, milestone, registry, UI, and indexer now read the Court's split basis points.                                             |
| 12  | MEDIUM   | Appeal stake accounting compared only the `Verdict` enum, so `SPLIT25 -> SPLIT75` looked "upheld" and slashed the appellant.                                                | Fixed. Appeal snapshots include `preAppealPayeeBps`; split appeals are upheld only when both the enum and bps match.                                                                   |
| 13  | MEDIUM   | ERC-20 fee-on-transfer underfunding. Token escrow accepted the requested amount even if the contract received fewer tokens.                                                  | Fixed. `createDeal` and token-stake appeal paths verify the balance delta equals the requested amount.                                                                                  |
| 14  | LOW      | Missing zero-address constructor guards in several consumers/support modules.                                                                                                 | Fixed. Constructors now reject zero Court, treasury, token, and platform addresses where applicable.                                                                                    |
| 15  | LOW      | Prompt-injection surface in dispute evidence. A party could attempt to close an evidence block and inject verdict instructions into the panel prompt.                         | Fixed. Evidence is fenced, angle brackets are stripped, and tests assert the allowed-values set remains deterministic.                                                                  |
| 16  | MEDIUM   | Shared consumer-base excess-fee refunds used a push transfer, so a non-receiving contract integrating the base could brick its own dispute when it overpaid.                 | Fixed. `VerdiktConsumerBase` now credits `pendingRefunds` and exposes `withdrawRefund`, matching the Court pull-refund pattern.                                                         |
| 17  | LOW      | `UNDECIDABLE` propagation gap in frontend/indexer tooling after abstention was enabled live.                                                                                  | Fixed. Demo UI, live case indexer, and agent SDK now recognize `UNDECIDABLE`; the UI lets the payee appeal an abstention refund path.                                                   |
| 18  | LOW      | Deployed CSP blocked the Google Fonts used by the landing/app pages, and deploy docs omitted linked app pages.                                                                | Fixed. CSP now allows the exact font origins and known RPC fallback; deploy docs include courtroom, explorer, and snapshot uploads.                                                     |

## Verification

- `forge test` passes 211/211, including fuzz and invariant tests.
- Regression coverage includes non-receiving settlement recipients, appeal-deadline snapshots,
  insurance capacity locks, pro-rata share minting, micro-funder appeal rejection, registry
  quote-revert skipping, no-return ERC-20 transfers, fee-on-transfer rejection, graded split
  settlement, split-bps appeal changes, Court/consumer-base pull-refunds, and prompt-injection fencing.
- `node --check` passes for keeper, indexer, SDK, and determinism/benchmark drivers.
- `npm audit --audit-level=high` reports 0 vulnerabilities for keeper, script, and indexer.

## Hardening & New Surface (current iteration)

The hardened stack is deployed live as **v4** (see `deployments/shannon.json`).

- **Prompt injection (VerdiktCourt).** Evidence was free text concatenated into the panel prompt.
  Now `_sanitizeEvidence` strips `<`/`>` so a party cannot forge the `<evidence>` fence, the evidence
  is fenced, and the system prompt marks it untrusted. Validated live (the panel ignored an embedded
  "output PAYEE" injection and ruled on facts) — see `injectionGate`. Residual: this raises the bar,
  it is not a proof; the live gate + red-team suite (`test/PromptInjection.t.sol`) are the evidence.
- **Prompt as governed law (VerdiktCourt).** Prompts are versioned, immutable per version, and
  governed (owner→timelock); each case snapshots its version, so a verdict is auditable against the
  exact prompt that decided it. A malicious governor could publish a biased prompt — mitigated by the
  timelock (transparent + delayed) and per-case citation.
- **Verifiable evidence (VerdiktAttestationRegistry).** Trusted attestors post facts the Court folds
  in as authoritative. Trust = governance over the attestor set; a registered-but-compromised attestor
  could post a misleading "fact". Facts are NOT sanitized (trusted source) — production should vet
  attestors and may want to sanitize facts too. Append-only per subject.
- **Abstention (VerdiktCourt).** Opt-in `UNDECIDABLE`; all six consumers settle it to the safe default
  (refund the payer/depositor). Validated live (clear→decisive, insufficient→UNDECIDABLE) before
  enabling — see `abstentionGate`.
- **Marketplace (VerdiktMarketplace).** Stake/slash via pull-payments (no brick). Challenge resolution
  is centralized to the owner/timelock arbiter — a future version could route court-quality disputes to
  a court itself. `slashBps` bounded ≤ 100%.
- **Keeper bounty (VerdiktKeeperBounty).** Permissionless; checks-effects-interactions (sets
  `claimed`/zeros `pot` before paying) → no reentrancy on claim/reclaim. Funders can `reclaim` until
  claimed.
- **Reference examples** (`SimpleEscrow`, `VerdiktPredictionMarket`, `VerdiktConsumerBase`) are teaching
  integrations — tested, not production-audited.

## Remaining Production Work

- Run an external audit + a bug bounty before mainnet.
- Replace caller-asserted `VerdiktReputation.record(... side ...)` with consumer-sourced party
  data in a production reputation module.
- Port the v4 hardening to the four extra consumers (AgentEscrow / TokenEscrow / GrantClawback /
  Milestone are built but not yet redeployed) when needed live.
