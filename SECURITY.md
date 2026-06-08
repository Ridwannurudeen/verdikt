# Verdikt - Security Notes

Internal audit of `VerdiktCourt`, `VerdiktEscrow`, `VerdiktInsurance`, `VerdiktAgentEscrow`,
`VerdiktTokenEscrow`, `VerdiktConsumerBase`, and the support tooling (updated 2026-06-08). Unaudited hackathon code on
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
| 19  | LOW      | Static frontend pages interpolated RPC/client error strings into `innerHTML`, and a few external links opened new tabs without `rel="noopener"`.                              | Fixed. Error strings are HTML-escaped before rendering, and all audited new-tab links now include `rel="noopener"`.                                                                      |
| 20  | MEDIUM   | Case policy snapshot gap. A case snapshotted prompt/model, but an already-open case's appeal could inherit later `gradedSplit` / `allowAbstention` toggle changes.            | Fixed. Each case now snapshots the label-set policy at open time; appeals reuse that policy. `setAgentId(0)` is also rejected after deployment.                                         |

## Verification

- `forge test` passes 230/230, including fuzz and invariant tests.
- Regression coverage includes non-receiving settlement recipients, appeal-deadline snapshots,
  insurance capacity locks, pro-rata share minting, micro-funder appeal rejection, registry
  quote-revert skipping, no-return ERC-20 transfers, fee-on-transfer rejection, graded split
  settlement, split-bps appeal changes, Court/consumer-base pull-refunds, prompt-injection fencing,
  model pinning, and per-case label-set snapshots.
- `npx solhint "src/**/*.sol" "test/**/*.sol" "script/**/*.sol"` runs with 0 errors. Remaining
  warnings are style/test-layout warnings plus reviewed production patterns: low-level calls for
  pull payments and optional/no-return ERC-20 support, Court/Insurance state count, and Court
  evidence sanitizer assembly.
- `python -m slither . --filter-paths "lib|test|script|out|cache"` runs through the repo. The
  hardening pass reduced findings from 120 to 78; remaining production findings are reviewed
  design patterns or static-analyzer limitations: pull-payment/native bounty sends, deadline
  timestamp comparisons, token balance-delta equality used to reject fee-on-transfer tokens,
  request-id mappings that must be written after the platform returns, and registry/marketplace
  live quote calls inside bounded listing scans.
- `node --check` passes for keeper, indexer, SDK, and determinism/benchmark drivers.
- `npm audit --audit-level=high` reports 0 vulnerabilities for keeper, script, and indexer.

## Hardening & New Surface (current iteration)

The hardened demo stack is deployed live as the June 7 **premium stack** (see `deployments/shannon.json`).

- **Prompt injection (VerdiktCourt).** Evidence was free text concatenated into the panel prompt.
  Now `_sanitizeEvidence` strips `<`/`>` so a party cannot forge the `<evidence>` fence, the evidence
  is fenced, and the system prompt marks it untrusted. Validated live (the panel ignored an embedded
  "output PAYEE" injection and ruled on facts) — see `injectionGate`. Residual: this raises the bar,
  it is not a proof; the live gate + red-team suite (`test/PromptInjection.t.sol`) are the evidence.
- **Prompt and label set as governed law (VerdiktCourt).** Prompts are versioned, immutable per
  version, and governed (owner→timelock); each case snapshots its prompt version, model id, and
  graded/abstention label policy, so a verdict is auditable against the exact rules that decided it.
  A malicious governor could publish a biased prompt — mitigated by the timelock (transparent +
  delayed) and per-case citation.
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
  claimed. Zero-address court funding is rejected so bounty funds cannot be stranded on an
  unclaimable target.
- **Reentrancy hardening.** Court, token/native escrows, insurance, grant clawback, milestone,
  marketplace, and the consumer base now use a local reentrancy guard around external court/platform,
  token, callback, and withdrawal boundaries. Refund accounting is credited before downstream
  calls when the fee is already known, relying on normal EVM rollback if the downstream call fails.
- **Reference examples** (`SimpleEscrow`, `VerdiktPredictionMarket`, `VerdiktConsumerBase`) are teaching
  integrations — tested, not production-audited.

## Internal pre-submission audit (2026-06-08)

A multi-area review (core court, consumers, infra layers, frontend, off-chain) plus `forge lint` and the full 230-test suite. **No critical/high fund-loss, access-control, or reentrancy bugs were found** — money math, `onVerdict` access control, pull-payment CEI, and the new features (model-pinning, two-sided evidence, attestation, abstention, adaptive panel) all verified sound.

**Fixed in this pass:**
- *(Medium)* Attested facts were concatenated into the panel prompt **unsanitized**; now run through `_sanitizeEvidence` like party evidence so a registered attestor can't forge the evidence fence (`VerdiktCourt._verifiedFacts`).
- *(Medium)* The two-sided escrow's combined statement let a party forge the counterparty's section header; statements are now cleaned of newlines/angle-brackets before composition (`VerdiktEscrow._combinedStatement` / `_clean`).
- *(Low)* `setKeeperCutBps` was capped at 100%, letting the owner redirect an entire slashed stake to treasury; now capped at 20% across Escrow/AgentEscrow/TokenEscrow/Insurance.
- *(Low)* `SimpleEscrow.dispute` lacked a `!settled` guard (re-dispute of a settled deal) — added.
- *(Off-chain)* `script/auto-arena.mjs`: reads `dealId` from the `DealCreated` event (was a `nextDealId` race), gates `finalize` on chain time (not wall clock), handles `Errored` cases explicitly, and uses a dual-RPC fallback transport.

**Accepted / documented (not changed — design-level or risk-vs-reward before deadline):**
- *(Medium)* `VerdiktReputation.record` trusts the caller-asserted party/side — reputation is advisory; a proper fix reads parties from the consumer (roadmap). Noted in NatSpec.
- *(Low)* Free `openDispute` can grief a deal into the dispute state without paying the court fee until `convene`; mitigated by the response-window timeout, flagged as a fee-timing roadmap item.
- *(Low)* `VerdiktRegistry.record` is permissionless with a caller-chosen topic (a front-runner can mis-topic a case once); ruling data itself is read from the trusted court and is correct.
- *(Low)* Frontend loads viem from esm.sh without SRI and sets no CSP — supply-chain/defense-in-depth; self-hosting viem + a CSP header are recommended for production.
- The injection-hardening is defense-in-depth on top of an LLM, not a formal guarantee; attestors are governance-gated and trusted.

## Known limitations / accuracy

- See [`ACCURACY.md`](ACCURACY.md) for the honest accuracy treatment (92% agreement / 100%
  byte-identical convergence on 12 curated disputes, the one divergent case, the real-money
  error risk, and the appeal / abstention / human-escalation mitigations), and
  [`TRUST-MODEL.md`](TRUST-MODEL.md) for the determinism dependency on Somnia's validator LLM.

## Internal pre-submission audit (2026-06-08)

Multi-area review (core court, consumers, infra, frontend, off-chain) + `forge lint` + the full test suite. **No critical/high fund-loss, access-control, or reentrancy bugs** — money math, `onVerdict` access control, pull-payment CEI, and the new features (model-pinning, two-sided evidence, attestation, abstention, adaptive panel) verified sound. Frontend verified clean on DOM-XSS (`esc()`/`textContent` on every on-chain string).

Fixed in this pass:
- *(Medium)* Attested facts were folded into the panel prompt **unsanitized**; now run through `_sanitizeEvidence` like party evidence so a registered attestor can't forge the evidence fence (`VerdiktCourt._verifiedFacts`).
- *(Medium)* The two-sided escrow's combined statement let a party forge the counterparty's section header; statements are now cleaned of newlines/angle-brackets (`VerdiktEscrow._combinedStatement` / `_clean`).
- *(Low)* `setKeeperCutBps` capped at 100% → now 20% across Escrow/AgentEscrow/TokenEscrow/Insurance, so a slashed stake can't be fully redirected to treasury.
- *(Low)* Added a `!settled` guard to `SimpleEscrow.dispute`.
- *(Off-chain)* `script/auto-arena.mjs`: reads `dealId` from the `DealCreated` event, gates `finalize` on chain time, handles `Errored` cases, and uses a dual-RPC fallback transport.

Accepted / documented (design-level or risk-vs-reward before deadline): caller-asserted `VerdiktReputation.record` (advisory; see Remaining Work), free `openDispute` griefing (mitigated by the response-window timeout), permissionless `VerdiktRegistry.record` topic, and frontend viem-from-CDN without SRI/CSP. Injection-hardening is defense-in-depth on an LLM, and attestors are governance-gated.

## Remaining Production Work

- Run an external audit + a bug bounty before mainnet.
- Replace caller-asserted `VerdiktReputation.record(... side ...)` with consumer-sourced party
  data in a production reputation module.
- Redeploy the extra consumers (AgentEscrow / TokenEscrow / GrantClawback / Milestone / Insurance)
  against the premium Court when those flows need to be demoed live.
