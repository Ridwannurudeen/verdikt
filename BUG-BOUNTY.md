# Verdikt — Bug Bounty

Verdikt is an AI-jury arbitration protocol for on-chain escrow on Somnia. Disputes are
settled by a consensus panel of on-chain LLM-inference agents (`PAYEE` / `PAYER` / `SPLIT`,
optional graded splits and `UNDECIDABLE` abstention) under Majority consensus, with a
stake-backed appeal layer. This program rewards researchers who find security issues in the
Solidity contracts before an external audit and mainnet deploy.

> **Status:** the code is currently live on **Somnia Shannon testnet** (chain 50312). It has
> had an internal review only (see [`SECURITY.md`](SECURITY.md)) — **no external third-party
> audit yet**. Reward amounts below are **PLACEHOLDER** and must be set by the program owner
> before this program is published.

---

## Scope

In-scope = the production Solidity in `src/` (and the shared evidence library). Source of
truth for live addresses is [`deployments/shannon.json`](deployments/shannon.json); the
current live stack is **premiumStack** plus the `resilientArena` / `serviceSLA` proofs noted there.

### In-scope contracts

| Contract | Area |
| --- | --- |
| `src/VerdiktCourt.sol` | Core AI-jury engine: panel request, consensus decode, appeal/escalation, finalize, governed prompt, attestation hook, 2-step ownership |
| `src/VerdiktConsumerBase.sol` | Inheritable consumer base (dispute open, fee/refund, verdict → payee bps) |
| `src/VerdiktEscrow.sol` | Two-party escrow with staked appeals + two-sided evidence |
| `src/VerdiktAgentEscrow.sol` | Machine-native agent-to-agent escrow (pull payments) |
| `src/VerdiktTokenEscrow.sol` | ERC-20-denominated escrow (fee-on-transfer guarded) |
| `src/VerdiktInsurance.sol` | Collateralized claims-arbitration pool (shares, coverage locks) |
| `src/VerdiktGrantClawback.sol` | DAO grant escrow (clawback / release) |
| `src/VerdiktMilestone.sol` | Freelance milestone escrow |
| `src/VerdiktRegistry.sol` | Append-only precedent index of final rulings |
| `src/VerdiktReputation.sol` | Per-party litigation record / score |
| `src/VerdiktAttestationRegistry.sol` | Governed trusted-attestor verified-fact registry |
| `src/VerdiktCourtRegistry.sol` | Court discovery (`cheapest()` by live quote/SLA) |
| `src/VerdiktMarketplace.sol` | Court staking / challenge / slash economics |
| `src/VerdiktKeeperBounty.sol` | Permissionless finalize-and-claim liveness bounty |
| `src/VerdiktTimelock.sol` | Delayed-execution governor that can own the Court |
| `src/lib/EvidenceLib.sol` | Deterministic structured-evidence formatter |
| `src/interfaces/*.sol` | Interface definitions (`IVerdiktCourt`, `IAgentRequester`, `ILLMAgent`, `IVerdiktAttestationRegistry`) — informational; report only if a mismatch causes a contract bug |

### Explicitly in-scope to challenge

The protocol's two headline guarantees are an invitation to break them:

- **Determinism / consensus integrity.** We claim the panel converges **byte-identically**
  so Majority consensus over `responses[0]` is meaningful (validated live: `determinismGate`,
  `gradedDeterminismGate`, `abstentionGate` in `deployments/shannon.json`). A reproducible way
  to make honest validators return divergent labels for the same evidence such that an
  attacker controls the settled verdict is in-scope.
- **Prompt-injection resistance.** Evidence is sanitized (`_sanitizeEvidence` strips `<`/`>`),
  fenced, and marked untrusted; the allowed-values set is fixed (tests in
  `test/PromptInjection.t.sol`, validated live: `injectionGate`). A crafted evidence/attestation
  payload that escapes the fence or otherwise steers the verdict away from the facts is in-scope.

---

## Severity classification

Severity follows impact × likelihood. Examples below are specific to an AI-arbitration escrow.

### Critical
Direct, unauthorized loss of user funds, or full subversion of the verdict pipeline.
- Draining escrowed deal value, appeal stakes, the insurance pool, or marketplace stakes to an
  attacker.
- Minting/withdrawing pull-payment (`pending[]`) credit that was never funded; breaking
  insurance share accounting to capture other funders' value.
- Forcing or forging a verdict / settlement without a real Court ruling (e.g. spoofing the
  platform callback, replaying a stale `onVerdict`).
- Reproducible verdict manipulation: prompt injection or determinism break that lets a party
  control the outcome of a real dispute.

### High
Loss or freezing of funds under specific (non-trivial) conditions, or theft limited in scope.
- Bricking finalization/settlement so disputed funds are permanently stranded (e.g. a
  push-payment regression — note finding #1 was fixed via pull payments).
- Appeal-stake slash computed against the wrong party or wrong amount (graded-split bps
  accounting errors — cf. findings #11/#12).
- Under-collateralization: selling coverage beyond free pool capacity, or withdrawing
  collateral backing active policies (cf. findings #2/#3).
- Double-settle / double-finalize of a case or deal.

### Medium
Limited fund impact, recoverable griefing, or privilege misuse within the trust model.
- Griefing/DoS: making a shared view (`cheapest()`, registry scan) revert for everyone (cf. #7),
  or stonewalling a dispute so it can never convene.
- Overpayment capture or refund-path bricking (cf. findings #5/#16).
- Micro-stake griefing of pool-side appeals or marketplace challenges (cf. #6).
- Access-control gaps on owner/timelock setters that fall outside the stated trust model.

### Low
Minor issues with marginal impact.
- Missing zero-address / input guards without a fund-loss path (cf. #14).
- ERC-20 compatibility edge cases already partially covered (cf. #8/#13).
- Event/accounting inconsistencies that don't move funds.

### Informational / out-of-reward
Style, gas, best-practice, or behavior already documented as accepted risk (see below).

---

## Out of scope

- **Anything testnet-only.** Shannon-specific deploy/gas quirks, faucet behavior, RPC outages,
  validator-count fluctuation (the `[3,5]` adaptive panel already degrades gracefully — see
  `resilientArena`/`adaptiveDemo`), and the demo-shortened `appealWindow` (60s) are not bugs.
- **Upstream Somnia behavior.** The Agents platform (`IAgentRequester`) enforcing
  `ConsensusType.Majority`, the LLM-inference agent's model output, validator subcommittee
  selection, and the off-chain receipt service are upstream of Verdikt and out of scope. (A
  bug in *how Verdikt builds the request or trusts the response* is in scope.)
- **Already-known / accepted risks** documented in `SECURITY.md`:
  - `handleVerdict` trusts `responses[0]` as canonical within the platform-Majority trust model
    (finding #10).
  - A malicious *governor* publishing a biased prompt — mitigated by the timelock + per-case
    prompt-version citation, not eliminated.
  - A registered-but-compromised *attestor* posting a misleading "fact" (attestation facts are
    trusted and not sanitized) — trust = governance over the attestor set.
  - `VerdiktReputation.record(...side...)` takes a caller-asserted `side` (the *verdict* is read
    authoritatively from the Court; only the side label is caller-supplied). Known simplification.
  - Agent-fee rebates accrue to the Court owner via `sweep` rather than per-request refunds.
- **Reference/teaching code, not production-audited:** `src/examples/SimpleEscrow.sol`,
  `src/examples/VerdiktPredictionMarket.sol`, and test mocks. Report only if they reveal a bug
  in an in-scope contract.
- Off-chain tooling (`keeper/`, `indexer/`, `sdk/`, `script/`, `ui/`, `web/`) unless a flaw
  there causes on-chain loss. Frontend hardening items #9/#17/#18/#19 are already fixed.
- Issues requiring a trusted role (owner/timelock/attestor) to act maliciously, beyond what is
  flagged above as in-scope.
- Theoretical determinism/injection concerns without a reproducible exploit path.

---

## Rewards — PLACEHOLDER (owner to set before publishing)

| Severity | Reward (PLACEHOLDER) |
| --- | --- |
| Critical | TODO — set amount/currency |
| High | TODO — set amount/currency |
| Medium | TODO — set amount/currency |
| Low | TODO — set amount/currency |
| Informational | TODO (discretionary / swag / none) |

Rules to finalize before launch (all **TODO**): payout currency and source, KYC requirements,
duplicate/first-reporter policy, decision/appeal process, and any maximum total pool.

---

## Reporting

- **Contact:** TODO — set a dedicated security contact (e.g. `security@<domain>` or a private
  disclosure form). Do **not** use public GitHub issues for vulnerabilities.
- **PGP key:** TODO (optional).
- **What to include:** affected contract + commit hash, a clear impact statement and severity
  rationale, and a **reproducible** proof of concept — a Foundry test against this repo is
  strongly preferred (see `test/` for the harness pattern and `test/mocks/MockAgentRequester.sol`
  for simulating panel responses).
- **Disclosure:** coordinated. Please give the team a remediation window (TODO — set days)
  before any public disclosure.
- **Safe harbor:** TODO — add a good-faith research safe-harbor statement.
