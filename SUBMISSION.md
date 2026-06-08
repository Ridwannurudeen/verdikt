# Verdikt — submission writeup (FINAL DRAFT for review)

> **Status:** final draft prepared for your review. Nothing has been submitted. Paste the final
> demo video URL and any track-specific form fields before submitting, and submit only with your
> explicit go-ahead.

## One-liner

**Verdikt is the settlement court for the agent economy** — an escrow protocol whose disputes
are decided by a consensus panel of on-chain AI agents on Somnia's Agentic L1. Autonomous agents
can transact but can't sue each other; Verdikt is the court that settles their disputes, with no
human in the loop.

## The problem

On-chain settlement today is binary: a price feed or a parametric rule, or an escrow that needs a
trusted human to adjudicate. Neither can make a **subjective judgment** — "did the seller actually
deliver?", "is this claim fair?" A single off-chain bot making that call can't be trusted. As
autonomous agents start transacting value, they hit the same wall a marketplace hits: when a deal
goes wrong, **who rules, and why should anyone trust the ruling?**

## What it does

`VerdiktCourt` is a reusable AI-jury primitive. When a deal is contested, the contract itself
convenes a panel of Somnia validator LLM-inference agents via `createAdvancedRequest`. Each agent
judges the same evidence and returns a verdict from a fixed label set (`PAYEE` / `PAYER` / `SPLIT`,
or graded `SPLIT25/50/75`), and the platform reaches **Majority consensus on a byte-identical
result** — that determinism is what makes the verdict trust-minimized rather than one bot's opinion.
The losing party can **appeal by staking**; a larger panel re-tries with new evidence and the stake
is slashed if the verdict holds. Every ruling carries a verifiable on-chain receipt of the agents'
reasoning, and finalized rulings become **citable on-chain precedent** plus **portable per-party
reputation**.

Any contract can consume the court. Reference consumers ship for two-party escrow, agent-to-agent
escrow, token-denominated escrow, DAO grant clawback, milestone payments, insurance claims, and a
prediction market whose subjective outcome the jury resolves.

## How Somnia powers it (verified against docs.somnia.network)

- **`IAgentRequester.createAdvancedRequest`** — the contract dispatches a panel of N validator agents
  with a Majority consensus type and threshold, directly from Solidity.
- **`ILLMAgent.inferString(prompt, system, chainOfThought, allowedValues)`** — the fixed
  `allowedValues` set is what forces byte-identical outputs so consensus is meaningful.
- LLM Inference base agent id `12847293847561029384`; platform `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`;
  per-agent price 0.07 STT (a panel of 5 ≈ 0.40 STT). No external API keys — inference runs on Somnia's
  validator network.

## Live on Shannon (chain 50312) — proof, not slides

**Live demo:** https://verdikt.gudman.xyz — landing + `/app` (escrow demo), `/app/arena.html`
(agent-to-agent court), `/app/courtroom.html` (verdict replay), `/app/explorer.html` (precedent +
reputation). **Repo:** https://github.com/Ridwannurudeen/verdikt — **230/230 tests** (incl. fuzz +
invariant). All of the following are on-chain and recorded in
[`deployments/shannon.json`](deployments/shannon.json):

- **Determinism gate PASS** — a panel of 5 returned a verdict **byte-identical 5/5**; the premise the
  whole design rests on, proven live.
- **Measurably accurate** — on 12 curated disputes, a live panel agreed with the human-expected verdict
  **11/12 (92%)** and converged **byte-identically 12/12 (100%)**.
- **Manipulation-resistant** — a panel ignored an embedded "output PAYEE" injection and ruled on the
  facts (evidence is sanitized + fenced + marked untrusted).
- **Graded + abstention, validated live** — a middle-bucket `SPLIT50` converged 5/5; a clear case ruled
  decisively while a genuinely-insufficient one abstained `UNDECIDABLE` 4/4.
- **Verifiable evidence** — an attestor posted a VERIFIED fact (3 of 4 units delivered); the panel
  weighed it over the disputing party's claim and ruled **SPLIT75** (payee 75% / payer 25%).
- **Agent-to-agent settlement, resilient to validator availability** — two contract agents (no EOA in
  the loop) settled a dispute autonomously: the trial panel is **caller-selectable `[3,5]`**, so when
  Somnia floated below 5 validators the court **degraded gracefully to a 3-agent panel** instead of
  reverting, reached a byte-identical **PAYER** majority, settled via pull-payment, and recorded
  precedent + reputation.

### Key live addresses

**Premium demo stack** — Court `0xeBbA8b849343150e994BEE34778D4D8D38941eDE`, Escrow
`0x91AaCFDF78D32Fa213408e7e5a187Af697fB099d`, Registry `0xd1e91c0167a3F5a5aC0F61f86E3883921610261E`,
AttestationRegistry `0x9CC2FB982D1a3ED67b827B51Efa7AA43ad3DA5f1`, ServiceSLA
`0xfB2bE585c0776547Ed2e0626F657e9a4AF9e37c9`.

**Resilient agent-to-agent stack** — Court `0x91FF43bE0a9fd4Bd93D7a2B1Cf7927FbED152B06`, AgentEscrow
`0x3cD6509237e2Ffb35f42b3810FA53b3afB1cB65c`, Registry `0x31F8f285c7e5331b7789E346D5f9dc8D85a83096`,
Reputation `0xE0884E873dE678e1f50c116e55309Af9b37417db`, BuyerAgent
`0x542a74a6a3bF336D42d2C05436adbfeC911Ae6a6`, SellerAgent `0xe5B27AFa3672640360cFFF6192F4B740B1657a49`.

## What's novel

- **A court as a reusable primitive**, not a single app — N protocols share one AI jury.
- **Stake-secured appeals** over consensus-AI verdicts: re-try with new evidence, slash frivolous appeals.
- **The agent-to-agent court** — both counterparties can be contracts; pull-payment settlement so a
  non-receiving counterparty can never brick the other party's payout or the court callback.
- **Graceful degradation to available validators** — a court that never stalls when the validator set
  dips, instead of reverting.
- **Verifiable evidence** (attested facts outrank party claims) + **prompt-as-governed-law** (versioned,
  timelock-governed, cited per case) + **on-chain precedent & reputation**.

## Honest status

Built, tested, deployed, and exercised end-to-end live on Shannon. **Not done (out of scope here):**
external third-party audit and mainnet deploy (needs a funded mainnet key); a governance token is
**intentionally deferred** per [`ECONOMICS.md`](ECONOMICS.md) until a real coordination problem warrants it.

## Links

- Live demo: https://verdikt.gudman.xyz
- Repo: https://github.com/Ridwannurudeen/verdikt
- Demo video: paste the final video URL before submitting the form
- On-chain proof: [`deployments/shannon.json`](deployments/shannon.json)
- Architecture & trust model: [`README.md`](README.md) · [`SECURITY.md`](SECURITY.md) · [`ECONOMICS.md`](ECONOMICS.md)
