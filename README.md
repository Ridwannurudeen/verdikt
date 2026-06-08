# Verdikt — the settlement court for the agent economy

**Trustless AI arbitration on Somnia's Agentic L1.** Autonomous agents can pay each other on-chain — but they can't *sue* each other, and smart contracts can't weigh evidence and judge a dispute. Verdikt is the missing piece: when a deal is contested, the contract **autonomously convenes a panel of Somnia validator LLM agents** that read the evidence and return a binding, **byte-identical** verdict (`PAYEE` / `PAYER` / `SPLIT`, optionally graded, or `UNDECIDABLE`). The losing party can **appeal by staking**; a larger panel re-tries with new evidence and the stake is **slashed** if the verdict holds. No human in the loop.

> It's the dispute committee that on-chain escrow — and an entire agent economy — doesn't yet have.

## See it live (Somnia Shannon)

**https://verdikt.gudman.xyz** — all live, reading real on-chain data:

- [**Agent Arena**](https://verdikt.gudman.xyz/app/arena.html) — two autonomous agents transact, dispute, and settle with no human.
- [**Courtroom replay**](https://verdikt.gudman.xyz/app/courtroom.html) — a real case, step by step (verified evidence → verdict).
- [**Case-law ledger**](https://verdikt.gudman.xyz/app/caselaw.html) · [**Explorer**](https://verdikt.gudman.xyz/app/explorer.html) — on-chain precedent.
- [**Analytics**](https://verdikt.gudman.xyz/app/analytics.html) — the determinism + accuracy benchmark.
- [**Interactive demo**](https://verdikt.gudman.xyz/app/) — create a deal and dispute it yourself.

**Watch agents settle a dispute autonomously, end to end:**

```bash
# one funded BuyerAgent key in BUYER_PK; defaults target the live premium stack
node script/auto-arena.mjs        # createDeal → auto-dispute → AI verdict → finalize → record → withdraw
```

## How it maps to the Agentathon criteria

- **Agent-first design** — disputes are resolved by a panel of agents convened *by the contract itself* via `createAdvancedRequest`; the court is an open primitive any agent/contract invokes autonomously. The autonomous loop (`script/auto-arena.mjs`) runs the full lifecycle agent-to-agent.
- **Autonomous performance** — no human in the settlement loop: dispute → panel verdict → (optional staked appeal → larger panel) → permissionless `finalize` settles and slashes. A keeper drives `finalize`/auto-release.
- **Innovation** — *judgment as an on-chain oracle*: byte-identical AI consensus, a stake-secured appeal layer, verifiable-evidence attestation, abstention, model + prompt versioning per verdict.
- **Functionality** — full lifecycle implemented and tested (**227/227**, incl. invariant/fuzz), **deployed and exercised live on Shannon** with real settlements across multiple apps.

## What makes the AI jury trustworthy

The hard part isn't convening a panel — it's making the verdict defensible. All of the following are **live on the June-7 premium stack** and recorded in [`deployments/shannon.json`](deployments/shannon.json):

- **Deterministic.** A fixed allowed-values set makes panel outputs byte-identical, so Majority consensus is meaningful. Proven live (determinism gate PASS).
- **Grounded in verified evidence.** Trusted attestors (oracles/courier APIs/EAS bridges) post on-chain facts the Court folds in as *authoritative*, above the parties' untrusted claims. **Proven live:** a buyer's false "never received" claim lost to the seller because an oracle had attested delivery.
- **Manipulation-resistant.** Evidence is sanitized + fenced and marked untrusted; a panel ignored an embedded "output PAYEE" injection and ruled on the facts (`injectionGate`).
- **Able to abstain.** Returns `UNDECIDABLE` on genuinely insufficient evidence instead of guessing, falling back to a safe default. **Proven live** (one-sided unverified claim → abstain; oracle-attested → decisive).
- **Measurably accurate.** On 12 curated disputes a live panel agreed with the human-expected verdict **11/12 (92%)** and converged **byte-identically 12/12 (100%)** (`script/run-benchmark.mjs`). ~8% error is mitigated by appeals + abstention + a documented human-escalation path — see [`ACCURACY.md`](ACCURACY.md).
- **Auditable per verdict.** Each case pins the **prompt version** (the court's versioned, timelock-governable "law") and the **model id** that decided it (`modelOf`).
- **Resilient.** The trial panel is caller-selectable in `[3, 5]`; when validators dip below full strength a dispute **degrades gracefully** instead of reverting (proven live at a 3-agent byte-identical majority).

The honest trust boundary (the dependency on Somnia's validator LLM) is documented plainly in [`TRUST-MODEL.md`](TRUST-MODEL.md).

## Architecture

```
Consumer (e.g. VerdiktEscrow)      VerdiktCourt (reusable arbitration primitive)        Somnia Agents
  createDeal / release               openCase ─┐                                         (validator
  dispute  ───────────────────────▶  appeal    ├─▶ createAdvancedRequest ──────────────▶  subcommittee
  appeal (stake)                      finalize ─┘    (panel N, Majority M-of-N)            runs LLM
  onVerdict ◀── settle + slash ◀───  handleVerdict ◀── consensus result + receiptId ◀────  inference)
```

- **`src/VerdiktCourt.sol`** — the reusable AI-jury engine: builds the request with a fixed allowed-values set, dispatches a panel via `createAdvancedRequest`, decodes the consensus verdict in `handleVerdict`, snapshots the prompt + model id per case, manages the appeal window + escalation, and finalizes. Any contract can consume it.
- **`src/VerdiktConsumerBase.sol`** — inherit-and-go base: a new protocol plugs in the jury in a few lines (implement one `_settle`).

### Consumers — many protocols, one court
Six production consumers settle on the same Court, proving it as a shared primitive: **`VerdiktEscrow`** (two-party, stake-backed appeals, two-sided evidence), **`VerdiktInsurance`** (claims pool), **`VerdiktAgentEscrow`** (machine-native, pull-payment — *agents can't sue each other; now they can*), **`VerdiktTokenEscrow`** (ERC-20 value), **`VerdiktGrantClawback`** (DAO grants), **`VerdiktMilestone`** (freelance). Plus reference integrations in [`src/examples/`](src/examples): **`ServiceSLA`** (an SLA-breach arbiter — *judgment as an oracle for autonomous services*, see [`CASE-STUDY.md`](CASE-STUDY.md)), `SimpleEscrow`, `VerdiktPredictionMarket`.

### Protocol layers
- **`VerdiktRegistry`** — append-only **precedent** index of final rulings (citable, AI-authored case law).
- **`VerdiktReputation`** — portable, court-verified litigation record per party (an agent's credential).
- **`VerdiktAttestationRegistry`** — **verifiable evidence**: governed attestors post authoritative on-chain facts.
- **`VerdiktMarketplace`** / **`VerdiktCourtRegistry`** — court **economics + discovery** (operators stake to back a court, challenges are bonded + slashed, `bestCourt()` routes by quality).
- **`VerdiktKeeperBounty`** — permissionless **liveness market**. **`VerdiktTimelock`** — delayed-execution governor that can own the Court.
- **`src/lib/EvidenceLib.sol`** — deterministic structured-evidence formatter ([schema](sdk/evidence-schema.md)).
- **SDK + tooling** — [`sdk/`](sdk/README.md) (Foundry lib + JS client + **agent SDK**), `script/auto-arena.mjs` (autonomous agent loop), `keeper/` (auto-finalize), `indexer/`.
- **Design docs** — [`TRUST-MODEL.md`](TRUST-MODEL.md) · [`ACCURACY.md`](ACCURACY.md) · [`SECURITY.md`](SECURITY.md) · [`ECONOMICS.md`](ECONOMICS.md) · [`ECONOMICS-SECURITY.md`](ECONOMICS-SECURITY.md) · [`PORTABILITY.md`](PORTABILITY.md) · [`AUDIT-READINESS.md`](AUDIT-READINESS.md) · [`BUG-BOUNTY.md`](BUG-BOUNTY.md) · [`MAINNET-RUNBOOK.md`](MAINNET-RUNBOOK.md).

## Live on Shannon (chain 50312)

The **current demo runs the premium stack** — model-pinned Court, two-sided evidence, adaptive 3–5 panels, abstention, and the attestation registry. Full history (v1–v4 + the resilient A2A arena + every determinism/injection/abstention gate) is in [`deployments/shannon.json`](deployments/shannon.json).

| Contract | Address |
| --- | --- |
| VerdiktCourt (model-pin · abstention · attestation) | `0xeBbA8b849343150e994BEE34778D4D8D38941eDE` |
| VerdiktEscrow (two-sided evidence) | `0x91AaCFDF78D32Fa213408e7e5a187Af697fB099d` |
| VerdiktRegistry (precedent) | `0xd1e91c0167a3F5a5aC0F61f86E3883921610261E` |
| VerdiktAttestationRegistry | `0x9CC2FB982D1a3ED67b827B51Efa7AA43ad3DA5f1` |
| ServiceSLA (reference integration) | `0xfB2bE585c0776547Ed2e0626F657e9a4AF9e37c9` |

**Proven live, end to end:**
- **Determinism gate PASS** — panels return byte-identical verdicts (the premise the whole design rests on).
- **Verifiable evidence** — an attested delivery fact overrode a false claim → **PAYEE**.
- **Abstention** — an unverified one-sided claim → **UNDECIDABLE** → safe refund; an oracle-attested outage → **decisive** refund.
- **Autonomous loop** — agents transacted, disputed, and settled with zero human input (`script/auto-arena.mjs`).
- **Precedent ledger** — **4 real rulings** across escrow + ServiceSLA + the autonomous loop (PAYEE / PAYER / UNDECIDABLE), browsable at [`/app/caselaw.html`](https://verdikt.gudman.xyz/app/caselaw.html).

## Build, test, deploy

```bash
forge build
forge test                         # 227/227 (solc 0.8.24, evm_version cancun)
cp .env.example .env               # PRIVATE_KEY + LLM_AGENT_ID (from agents.somnia.network)
forge script script/Deploy.s.sol --rpc-url shannon --broadcast
```

> **Gas note:** Somnia meters deployment well above mainnet and `eth_estimateGas` under-reports — deploy with an explicit high `--gas-limit` (we use 50–120M). See [`MAINNET-RUNBOOK.md`](MAINNET-RUNBOOK.md).

### Determinism gate (verify the premise yourself)
The AI-jury premise rests on deterministic inference converging across validators. Verify it live:
```bash
forge script script/Probe.s.sol:ProbeDeploy --rpc-url shannon --broadcast   # note the probe address
cd script && npm install && node run-determinism-gate.mjs <PROBE_ADDR>       # fires a panel, prints a verdict histogram
```
**PASS** = top label count equals panel size (byte-identical convergence). Details in [`script/README-determinism.md`](script/README-determinism.md).

## Somnia integration (verified against docs.somnia.network)

- Platform `IAgentRequester` — testnet `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776` (chain 50312), mainnet `0x5E5205CF39E766118C01636bED000A54D93163E6` (5031).
- `createAdvancedRequest(agentId, cb, selector, payload, subcommitteeSize, threshold, ConsensusType.Majority, timeout)` → `handleResponse` callback.
- LLM Inference agent `inferString(prompt, system, chainOfThought, allowedValues)`; per-agent price 0.07 STT (panel 5 ≈ 0.40 STT).

## Status & honest limitations

Phases 0–5 are built, tested (**227/227**), and live on Shannon (full [`ROADMAP.md`](ROADMAP.md)). Honest gaps:

- **Reference deployment, not external adoption** — real on-chain verdicts, but the cases were self-driven; a real external integrator is the next growth step.
- **No third-party audit yet** — [`AUDIT-READINESS.md`](AUDIT-READINESS.md) + [`BUG-BOUNTY.md`](BUG-BOUNTY.md) are prepared; audit is the gate before mainnet.
- **Trust boundary** — verdict reproducibility depends on Somnia's validator LLM (which Verdikt records per case but can't freeze upstream); detected via re-runnable gates, documented in [`TRUST-MODEL.md`](TRUST-MODEL.md).
- **Appeal panel (9 agents)** exceeds Shannon's current validator subcommittee, so the staked-appeal escalation is unit-tested but runs live only on a larger set.
- Rerun the determinism gates after any prompt or label-set change.
