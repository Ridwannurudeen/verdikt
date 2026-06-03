# Verdikt — trustless AI arbitration for on-chain escrow

Verdikt is an escrow protocol whose disputes are settled by a **consensus panel of on-chain AI agents** on Somnia's Agentic L1. When a deal is contested, the contract autonomously convenes a panel of LLM-inference agents that review the evidence and return a binding verdict (`PAYEE` / `PAYER` / `SPLIT`, with optional graded split percentages) under Majority consensus. The losing party can **appeal by staking** — a larger panel re-tries the case with new evidence, and the stake is **slashed** if the original verdict holds. Every ruling carries a verifiable on-chain receipt of the agents' reasoning.

It is the dispute committee that on-chain escrow (and Somnia's own prediction markets) don't yet have.

## Why this needs the Agentic L1

A claims adjuster makes a _subjective judgment_ — something a price feed or rigid parametric rule can't do, and something a single off-chain bot can't be trusted to do. Somnia's agents make AI judgment **trust-minimized**: a subcommittee of validators each runs the inference, and consensus is reached on a byte-identical result. Verdikt turns that primitive into a settlement layer.

## Architecture

```
VerdiktEscrow (consumer)            VerdiktCourt (reusable arbitration primitive)        Somnia Agents
  createDeal / release                openCase ─┐                                          (validator
  dispute  ────────────────────────▶  appeal    ├─▶ createAdvancedRequest ───────────────▶  subcommittee
  appeal (stake)                       finalize ─┘     (panel N, Majority M-of-N)             runs LLM
  onVerdict ◀── settle + slash ◀────  handleVerdict ◀── consensus result + receiptId ◀──────  inference)
```

- **`src/VerdiktCourt.sol`** — the reusable AI-jury engine. Builds an `inferString` request with a fixed allowed-values set (`PAYEE/PAYER/SPLIT`, or opt-in `PAYER/SPLIT25/SPLIT50/SPLIT75/PAYEE`) so panel outputs are byte-identical and Majority consensus is meaningful, dispatches a panel via `createAdvancedRequest`, decodes the consensus verdict in `handleVerdict`, manages the appeal window + escalation (panel 5 → 9), and finalizes. Any contract can consume it.
- **`src/interfaces/`** — `IAgentRequester` (Somnia platform, verbatim from the docs), `ILLMAgent` (inference method signatures), `IVerdiktCourt`.

## Consumers — N protocols, one court

Six independent consumers settle on the same Court, proving it as a shared primitive:

- **`src/VerdiktEscrow.sol`** — two-party escrow with stake-backed appeals (slash on upheld, return on overturned). Settlement uses pull payments (`pending[]` + `withdraw()`) so a reverting recipient cannot brick finalization.
- **`src/VerdiktInsurance.sol`** — collateralized claims-arbitration pool. Funders deposit STT and receive pro-rata shares; insured users buy policies only when the pool has free capacity, then file claims the court arbitrates (`PAYEE` pays full coverage, `SPLIT` half, `PAYER` nothing). Either side can appeal; pool-side appeals require meaningful share ownership.
- **`src/VerdiktAgentEscrow.sol`** — machine-native escrow for the **agent-to-agent court**: both counterparties may be contracts/agents and the whole lifecycle is code-callable. Settles via **pull payments** (`pending[]` ledger + `withdraw()`) so a non-receiving counterparty can't brick the court callback. _Autonomous agents can't sue each other — now they can._
- **`src/VerdiktTokenEscrow.sol`** — ERC-20-denominated, pull-payment escrow: deal value + stakes in a token, court fees still native STT. It rejects fee-on-transfer underfunding so escrow accounting cannot over-credit deposits. _Agents settle real stablecoin value._
- **`src/VerdiktGrantClawback.sol`** — DAO grant escrow (`PAYER` = clawback to the DAO, `PAYEE` = release to grantee).
- **`src/VerdiktMilestone.sol`** — freelance milestone escrow (`PAYEE` = pay freelancer, `PAYER` = refund client).

## Protocol layers

- **`src/lib/EvidenceLib.sol`** — deterministic structured-evidence formatter; an agent assembles dispute evidence (parties, amount, deadline, claim, `priorCaseId` for precedent) into a byte-identical string. Schema in [`sdk/evidence-schema.md`](sdk/evidence-schema.md).
- **`src/VerdiktRegistry.sol`** — the **precedent layer**: a permissionless, append-only index of _final_ rulings (queryable by topic/consumer). On-chain, AI-authored, citable case law.
- **`src/VerdiktReputation.sol`** — a portable, court-verified litigation record per party (wins/losses/splits, `scoreOf`). An agent's dispute history becomes a credential.
- **`src/VerdiktAttestationRegistry.sol`** — **verifiable evidence**: governed trusted attestors (oracles, courier APIs, EAS bridges) post on-chain facts the Court folds into the prompt as _authoritative_, above the parties' untrusted claims. Verdicts rest on attested truth, not just assertions.
- **`src/VerdiktCourtRegistry.sol`** — court **discovery**: operators list competing courts; `cheapest()` shops by live price/SLA.
- **`src/VerdiktMarketplace.sol`** — court **economics**: operators _stake_ to back a court, anyone _challenges_ a bad ruling for a bond, governance slashes on upheld, and `bestCourt()` routes by quality. A market for justice with skin in the game.
- **`src/VerdiktKeeperBounty.sol`** — permissionless **liveness market**: fund a bounty to get a case finalized; any keeper settles it and takes the pot.
- **`src/VerdiktTimelock.sol`** — delayed-execution governor that can own the Court, removing single-key owner trust.
- **`src/VerdiktConsumerBase.sol`** — inherit-and-go base so a new protocol integrates the jury in a few lines (see [`src/examples/`](src/examples): `SimpleEscrow`, `VerdiktPredictionMarket`).
- **SDK + tooling** — [`sdk/README.md`](sdk/README.md) (Foundry lib + JS client + agent SDK), `keeper/` (auto-finalize), `indexer/`, and four live app pages: escrow demo, **courtroom replay** (`ui/courtroom.html`), **case-law explorer** (`ui/explorer.html`), case-law dashboard.
- **Design** — [`SECURITY.md`](SECURITY.md) (audit), [`ECONOMICS.md`](ECONOMICS.md) (fee model + anti-frivolous-appeal math), [`PORTABILITY.md`](PORTABILITY.md) (beyond Somnia).

## What makes the AI jury trustworthy

The hard part of an AI court isn't convening a panel — it's making the verdict defensible. All of the
following are live on Shannon (**v4**) and recorded in [`deployments/shannon.json`](deployments/shannon.json):

- **Manipulation-resistant.** Evidence is sanitized + fenced and the prompt marks it untrusted, so a
  party can't inject instructions. Proven live: a panel ignored an embedded "output PAYEE" and ruled on
  the facts (`injectionGate`).
- **Measurably accurate.** On 12 curated disputes, a live panel agreed with the human-expected verdict
  **11/12 (92%)** and converged **byte-identically 12/12 (100%)** (`accuracyBenchmark`, reproduce with
  `script/run-benchmark.mjs`).
- **Grounded in attested facts**, not just claims (the attestation registry above).
- **Able to abstain** — `UNDECIDABLE` when evidence is genuinely insufficient, rather than guessing
  (validated live: clear→decisive, insufficient→abstain).
- **Governed transparently** — the prompt is the court's "law": versioned, immutable per version,
  timelock-governed, and cited per case.
- **Graded outcomes** — `SPLIT25/50/75` for partial fault, determinism-validated live.

## How it maps to the judging criteria

- **Agent-First Design** — disputes are resolved by a panel of agents convened _by the contract itself_ via `createAdvancedRequest`; the court is an open primitive any agent/contract can invoke autonomously.
- **Autonomous Performance** — no human in the settlement loop: dispute → panel verdict → (optional staked appeal → larger panel) → permissionless `finalize` settles and slashes. A keeper can drive `finalize` / auto-release.
- **Innovation** — a stake-secured _appeal_ layer on top of consensus-AI verdicts; the appeal re-tries with **new evidence** (the honest design given deterministic inference) and slashes frivolous appeals.
- **Functionality** — full lifecycle implemented and unit-tested (**211/211 passing**, incl. invariant/fuzz) against a platform mock; the full stack has been **deployed and exercised live on Shannon** (determinism gate PASS, disputes settled, precedent + reputation recorded on-chain).

## Somnia integration (verified against docs.somnia.network)

- Platform `IAgentRequester` testnet `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776` (chain 50312), mainnet `0x5E5205CF39E766118C01636bED000A54D93163E6` (5031).
- `createAdvancedRequest(agentId, cb, selector, payload, subcommitteeSize, threshold, ConsensusType.Majority, timeout)`; `handleResponse` callback; `getAdvancedRequestDeposit`.
- LLM Inference agent `inferString(prompt, system, chainOfThought, allowedValues)`; per-agent price 0.07 STT (panel 5 ≈ 0.40 STT, panel 9 ≈ 0.72 STT).
- Each juror's chain-of-thought is recorded in the off-chain **receipt** (per-node, retrievable at `agents.somnia.network/receipts/<id>`); the on-chain verdict is the consensus value.

## Build & test

```bash
forge build
forge test            # 211/211 (solc 0.8.24, evm_version cancun)
```

## Deploy (Shannon testnet)

```bash
cp .env.example .env   # fill PRIVATE_KEY + LLM_AGENT_ID (from agents.somnia.network)
forge script script/Deploy.s.sol --rpc-url shannon --broadcast
```

## Determinism gate (run before trusting the design)

The AI-jury premise rests on deterministic LLM inference converging across validators. Verify it live in two commands.

**Prereqs:** a Shannon-funded `PRIVATE_KEY` (faucet at https://testnet.somnia.network) and a real `LLM_AGENT_ID` registered at https://agents.somnia.network in your `.env`.

**1. Deploy the probe.** Note the `DeterminismProbe:` address printed.

```bash
forge script script/Probe.s.sol:ProbeDeploy --rpc-url shannon --broadcast
```

**2. Fire + poll + histogram, in one command.** The driver computes the exact fee on-chain (`getAdvancedRequestDeposit(panel) + 0.07 STT * panel`), fires `fire(evidence, panel)`, polls `getResults()` every 10 s for up to 5 minutes, and prints a verdict-frequency histogram.

```bash
cd script && npm install
node run-determinism-gate.mjs <PROBE_ADDR>
```

**3. Interpret the output.**

```
verdict histogram
-----------------
  PAYER     5/5  100%  ########################

PASS: panel converged byte-identically.
```

- **PASS** — top label count equals panel size; the design's premise holds.
- **PARTIAL** — strict majority but not unanimous; consensus still settles, flag for review.
- **FAIL** — no majority. Edit `script/Probe.s.sol` to use the binary `["PAYEE", "PAYER"]` set and/or set `chainOfThought=false` in `fire()`, redeploy, re-run.

Driver details (env, exit codes, optional CLI args) are in [`script/README-determinism.md`](script/README-determinism.md).

## Live on Shannon (chain 50312)

The full stack is deployed and exercised end-to-end (all addresses + live demos in [`deployments/shannon.json`](deployments/shannon.json)).

> **Current = v4 (hardened):** the live demo runs the fully-hardened stack — injection-resistant governed
> prompt, graded SPLIT, abstention, and the attestation registry — at Court `0x8f2a01D63D3fC0216321970510D0dDFFe9693199`
> (Escrow `0x000c7dc0…`, Registry `0xe368032D…`, Reputation `0x14e82fE1…`, AttestationRegistry `0x53e76327…`,
> Marketplace `0xa51c712f…`). It settled a live dispute where an attested fact overrode a false claim →
> SPLIT 75%. The table below is the original v1 demo deployment, kept for history.

| Contract                           | Address                                      |
| ---------------------------------- | -------------------------------------------- |
| VerdiktCourt                       | `0xd427dcb15a03F6d3D92bd19a44a18c1e149C66ee` |
| VerdiktEscrow                      | `0xED2cBf8778BF397BE576bd4E033B7C1c4A056Ea6` |
| VerdiktInsurance                   | `0xEA462e024b6207B5311820864dC6a4cF64346Da4` |
| VerdiktAgentEscrow                 | `0x8788a859a00057a4660d6Fb15DE373719A565C92` |
| VerdiktTokenEscrow                 | `0xCCc7d99BF967313735f7BFA25b2E76e0C6993593` |
| VerdiktGrantClawback               | `0xDA7B9F52Ac7e71508E7C3B8FE95c27e28A7C441f` |
| VerdiktMilestone                   | `0xc8439c2E2d058661D664986a12CaE05Af463872D` |
| VerdiktRegistry (precedent)        | `0x161eD3da61b5D787FA1e40F77911b6404ceD4Ac7` |
| VerdiktReputation                  | `0x6fbD122af11236fB2ddbc99dcaF4f2F51cC4545B` |
| VerdiktCourtRegistry (marketplace) | `0xA4A2f908E627387ee13D1090A0461206e4374BD9` |
| VerdiktTimelock                    | `0x2E30F37F41BFfCd716C4D5d4023652f5ABCB8ca1` |

- **Determinism gate: PASS** — panel of 5 returned PAYEE 5/5 (byte-identical), the premise the whole design rests on.
- **Disputes settled live** — `createDeal → dispute → on-chain AI panel → verdict → finalize` settles to the winner with no human in the loop (verified for PAYER and PAYEE outcomes).
- **Precedent index is live** — 4 final rulings recorded into `VerdiktRegistry` (machine-generated case law on-chain); the live Court is listed in the marketplace; reputation is populated (the deployer's record reads 2 wins / 1 loss / score 3).
- **Gas note:** Somnia meters contract _deployment_ well above mainnet; `eth_estimateGas` under-reports, so deploy with an explicit high `--gas-limit` (we used 50–60M). State-write calls also need generous limits (a `createDeal` costs ~865k gas). See `deployments/shannon.json`.
- **Appeal panel (round 1 = 9 agents)** exceeds Shannon testnet's validator subcommittee (~6), so the staked-appeal path is unit-tested but runs live only on a larger validator set.

## Status / roadmap

The full [`ROADMAP.md`](ROADMAP.md) (Phases 0–5) is built, tested (211/211), and deployed live on Shannon:

- [x] **Phase 0** — Court/Escrow/Insurance + determinism gate **PASS** on Shannon; full dispute settled live.
- [x] **Phase 1** — keeper (`keeper/keeper.mjs`, cursor-scan for Somnia) + demo UI (`ui/index.html`); README/deck with live results.
- [x] **Phase 2** — security audit ([`SECURITY.md`](SECURITY.md)), invariant/fuzz tests, `evm_version` confirmed cancun.
- [x] **Phase 3** — agent-to-agent court (`VerdiktAgentEscrow`), ERC-20 settlement (`VerdiktTokenEscrow`), structured evidence (`EvidenceLib`), A2A SDK.
- [x] **Phase 4** — 6 consumers on one court, precedent registry (`VerdiktRegistry`), case-law indexer + dashboard.
- [x] **Phase 5** — arbitration marketplace, reputation, timelock governance, economics + portability designs.

Keeper polls Shannon for ruled cases past their appeal window and delivered deals past `deliverBy`, then calls `finalize`/`release` permissionlessly. Browser demo at `ui/index.html`; case-law dashboard at `ui/caselaw.html`.

## Known simplifications

- The live v4 Court/Escrow/Registry/Reputation/Attestation/Marketplace are current. Historical AgentEscrow/TokenEscrow/GrantClawback/Milestone/Insurance addresses should be redeployed before demoing those consumer-specific flows live.
- Agent-fee rebates accrue to the court (owner `sweep`), not refunded per-request.
- Graded SPLIT and abstention are implemented, tested locally, and validated live; rerun the determinism gates after any prompt or label-set change.
