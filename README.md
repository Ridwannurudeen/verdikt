# Verdikt — trustless AI arbitration for on-chain escrow

Verdikt is an escrow protocol whose disputes are settled by a **consensus panel of on-chain AI agents** on Somnia's Agentic L1. When a deal is contested, the contract autonomously convenes a panel of LLM-inference agents that review the evidence and return a binding verdict (`PAYEE` / `PAYER` / `SPLIT`) under Majority consensus. The losing party can **appeal by staking** — a larger panel re-tries the case with new evidence, and the stake is **slashed** if the original verdict holds. Every ruling carries a verifiable on-chain receipt of the agents' reasoning.

It is the dispute committee that on-chain escrow (and Somnia's own prediction markets) don't yet have.

## Why this needs the Agentic L1

A claims adjuster makes a *subjective judgment* — something a price feed or rigid parametric rule can't do, and something a single off-chain bot can't be trusted to do. Somnia's agents make AI judgment **trust-minimized**: a subcommittee of validators each runs the inference, and consensus is reached on a byte-identical result. Verdikt turns that primitive into a settlement layer.

## Architecture

```
VerdiktEscrow (consumer)            VerdiktCourt (reusable arbitration primitive)        Somnia Agents
  createDeal / release                openCase ─┐                                          (validator
  dispute  ────────────────────────▶  appeal    ├─▶ createAdvancedRequest ───────────────▶  subcommittee
  appeal (stake)                       finalize ─┘     (panel N, Majority M-of-N)             runs LLM
  onVerdict ◀── settle + slash ◀────  handleVerdict ◀── consensus result + receiptId ◀──────  inference)
```

- **`src/VerdiktCourt.sol`** — the reusable AI-jury engine. Builds an `inferString` request with `allowedValues = [PAYEE, PAYER, SPLIT]` (so panel outputs are byte-identical and Majority consensus is meaningful), dispatches a panel via `createAdvancedRequest`, decodes the consensus verdict in `handleVerdict`, manages the appeal window + escalation (panel 5 → 9), and finalizes. Any contract can consume it.
- **`src/interfaces/`** — `IAgentRequester` (Somnia platform, verbatim from the docs), `ILLMAgent` (inference method signatures), `IVerdiktCourt`.

## Consumers

- **`src/VerdiktEscrow.sol`** — two-party escrow with stake-backed appeals (slash on upheld, return on overturned). The flagship demo of the court as a settlement layer.
- **`src/VerdiktInsurance.sol`** — parametric claims-arbitration pool. Funders deposit STT into a shared pool and receive shares; insured users buy policies (premium routed to the pool) and file claims that the court arbitrates. `PAYEE` pays full coverage from the pool, `SPLIT` pays half, `PAYER` pays nothing. Either side can appeal by posting a stake — on uphold the stake is slashed to the counterparty minus a treasury cut, mirroring the escrow economics. Withdrawals are locked while any claim is open.

## How it maps to the judging criteria

- **Agent-First Design** — disputes are resolved by a panel of agents convened *by the contract itself* via `createAdvancedRequest`; the court is an open primitive any agent/contract can invoke autonomously.
- **Autonomous Performance** — no human in the settlement loop: dispute → panel verdict → (optional staked appeal → larger panel) → permissionless `finalize` settles and slashes. A keeper can drive `finalize` / auto-release.
- **Innovation** — a stake-secured *appeal* layer on top of consensus-AI verdicts; the appeal re-tries with **new evidence** (the honest design given deterministic inference) and slashes frivolous appeals.
- **Functionality** — full lifecycle implemented and unit-tested (35/35 passing) against a platform mock; deploys to Shannon testnet.

## Somnia integration (verified against docs.somnia.network)

- Platform `IAgentRequester` testnet `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776` (chain 50312), mainnet `0x5E5205CF39E766118C01636bED000A54D93163E6` (5031).
- `createAdvancedRequest(agentId, cb, selector, payload, subcommitteeSize, threshold, ConsensusType.Majority, timeout)`; `handleResponse` callback; `getAdvancedRequestDeposit`.
- LLM Inference agent `inferString(prompt, system, chainOfThought, allowedValues)`; per-agent price 0.07 STT (panel 5 ≈ 0.40 STT, panel 9 ≈ 0.72 STT).
- Each juror's chain-of-thought is recorded in the off-chain **receipt** (per-node, retrievable at `agents.somnia.network/receipts/<id>`); the on-chain verdict is the consensus value.

## Build & test

```bash
forge build
forge test            # 35/35
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

## Status / roadmap

- [x] Court + Escrow contracts, full unit test suite (35/35)
- [x] Deploy + determinism-probe scripts
- [ ] Run determinism gate on Shannon (needs funded key + real `LLM_AGENT_ID`)
- [x] Keeper (auto-finalize / auto-release) and minimal demo UI
- [x] Second consumer (insurance claim) to demonstrate the court as a primitive

Keeper lives in `keeper/keeper.mjs` — a single Node script that polls Shannon for ruled cases past their appeal window and delivered deals past `deliverBy`, then calls `finalize` / `release` permissionlessly. Minimal browser demo at `ui/index.html` — open via `python -m http.server -d ui 8080`.

## Known simplifications

- Agent-fee rebates accrue to the court (owner `sweep`), not refunded per-request.
- `evm_version = paris` until the Shannon EVM target is confirmed.
- `createAdvancedRequest` `timeout` units to confirm against the web-app generated code.
