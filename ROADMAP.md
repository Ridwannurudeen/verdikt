# Verdikt — Roadmap

**Vision:** Verdikt becomes the **settlement court for the autonomous agent economy** — the neutral
arbiter that on-chain agents need but don't have. Autonomous agents can transact, but they can't sue
each other; on a chain whose entire thesis is agents (Somnia's Agentic L1), subjective disputes have
no judge. `VerdiktCourt` is that judge: a reusable AI-jury primitive that *any contract or agent* can
convene, delivering verdicts programmatically (`onVerdict`) with stake-secured appeals and verifiable
per-juror receipts — no human in the settlement loop. Escrow is the on-ramp; the destination is
**judgment-as-a-service**: a subjective-truth oracle every dispute-bearing protocol on the chain
routes through. Start by winning the hackathon on the strength of a **live, premise-proven demo**;
then build it into invisible infrastructure toward mainnet.

**Status as of 2026-05-31:** code + local tests are done (35/35). Nothing has touched Shannon yet —
no `broadcast/` artifacts exist, and `LLM_AGENT_ID` is still empty in `.env`. The entire live path is
gated on registering a real agent. This roadmap is phased: **Phase 0–1 win the hackathon**, **Phase 2+
build the product**.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · 🔴 blocker · 🟡 needs external input

---

## Phase 0 — Prove the premise & go live (the win foundation)

The whole pitch rests on one unproven claim: *a validator subcommittee converges byte-identically on an
LLM verdict.* Until that's shown live, everything else is theory. This phase turns theory into a
working on-chain demo.

- [ ] 🔴🟡 **Look up the LLM Inference agent ID** and paste it into `.env` (`LLM_AGENT_ID=`). No
  registration or API key needed — it's a pre-deployed Phase-1 base agent. Open the **testnet** agent
  explorer (agents.testnet.somnia.network, to match the Shannon platform addr), select **LLM
  Inference**, copy its numeric id. Verify it resolves on Shannon before spending gas. This single
  value unblocks every item below. *(User action — I just need the id.)*
- [x] **Fund the deployer** — confirmed `0xFDc753d1b3967653bC8Dcc394a38FBf3ea5a6a58` holds **100 STT**
  on Shannon; covers all deploys (~0.10 STT) + panel fees (5 ≈ 0.40, 9 ≈ 0.72) many times over.
- [x] **Dry-run all scripts** — `forge build` green (lint warnings only); `Deploy`, `ProbeDeploy`,
  `DeployInsurance` all `SIMULATION COMPLETE` against live Shannon (chain 50312) with placeholder env,
  no broadcast. Deploy ≈ 0.058 STT, Probe ≈ 0.016, Insurance ≈ 0.030. `script/` + `keeper/` deps
  installed. **Only `LLM_AGENT_ID` remains to go live.**
- [ ] **Run the determinism gate.** Deploy `script/Probe.s.sol:ProbeDeploy`, then
  `cd script && npm install && node run-determinism-gate.mjs <PROBE_ADDR>`. Capture the histogram.
  - [ ] PASS → record the receipt id + screenshot for the deck/submission.
  - [ ] PARTIAL/FAIL → apply the documented fallback (binary `["PAYEE","PAYER"]` set and/or
    `chainOfThought=false` in `Probe.fire`), redeploy, re-run. Tick the README roadmap box either way.
- [ ] **Deploy the stack to Shannon.** `Deploy.s.sol` (Court + Escrow) then `DeployInsurance.s.sol`.
  Wire `setAgentId` on the Court. Record all addresses in a new `deployments/shannon.json`.
- [ ] **End-to-end live dispute.** Drive one full escrow lifecycle on Shannon:
  `createDeal → dispute → handleVerdict → finalize`, and one appeal that escalates panel 5 → 9.
  Confirm slashing/return economics match the tests.

**Exit criteria:** a real Shannon tx hash for a settled dispute + an agent receipt URL we can show on
screen. This is the hackathon's killer proof point.

---

## Phase 1 — Demo polish & submission-grade artifacts

Make the win legible to judges in under 3 minutes.

- [ ] **Wire the UI to live addresses.** `ui/index.html` reads from `deployments/shannon.json`; add a
  visible "View receipt" link per case (`agents.somnia.network/receipts/<id>`) so the AI reasoning is
  one click away — that's the differentiator, surface it.
- [ ] **Run the keeper live.** Point `keeper/keeper.mjs` at the deployed Court/Escrow; demonstrate
  permissionless `finalize`/`release` firing on `VerdictReached`/`Delivered` with no human in the loop.
- [ ] **Record a 2–3 min demo video** of the full loop (fund → dispute → panel verdict → appeal →
  slash → keeper auto-finalize), with the determinism histogram and a receipt on screen.
- [ ] **Update README + DECK** with the live tx hashes, addresses, and the determinism result.
  Replace "prepared but not run live yet" (DECK slide "Honest scope") with the actual outcome.
- [ ] **Housekeeping:** decide `DECK.html` fate (commit the rendered deck or add to `.gitignore`);
  confirm `verdikt.gudman.xyz` is actually live against `deploy/nginx-verdikt.gudman.xyz.conf`.
- [ ] **Submit** — only after explicit user approval (per standing rule).

**Exit criteria:** submission package = repo + live demo URL + video + on-chain proof. Hackathon-ready.

---

## Phase 2 — Harden the protocol (post-win, toward credibility)

Turn hackathon code into something defensible.

- [ ] **Confirm the unknowns** flagged in `foundry.toml` / README "Known simplifications":
  - [ ] `createAdvancedRequest` `timeout` units (verify against web-app generated code) and set
    `setRequestTimeout` correctly.
  - [ ] Shannon EVM target — bump `evm_version = "paris"` → `shanghai`/`cancun` if PUSH0/transient
    storage are supported. Re-run the full suite after.
- [ ] **Per-request fee accounting.** Today agent-fee rebates accrue to the Court (owner `sweep`).
  Refund overpayment per-request so consumers aren't silently overcharged.
- [ ] **Internal security review** (use `security-reviewer` agent): reentrancy on
  `appeal`/`finalize`/`release`, stake-accounting invariants, `onlyPlatform`/`onlyCourt` guards,
  griefing on the appeal window, fee-underpayment paths.
- [ ] **Invariant & fuzz tests** (Foundry): "escrowed funds always conserved", "slashed stake exactly
  conserved minus treasury cut", "no verdict settles twice". Expand beyond the 35 unit tests.
- [ ] **Gas + DoS pass** on string-evidence handling and panel escalation.

**Exit criteria:** clean internal review, invariant suite green, all "Known simplifications" resolved
or consciously documented.

---

## Phase 3 — The Agent-to-Agent Court (the flagship thesis)

**Autonomous agents can transact on-chain, but they cannot sue each other.** When an agent-to-agent
deal goes wrong, there is no neutral arbiter — and a chain whose entire thesis is autonomous agents
(Somnia's Agentic L1) needs one. `VerdiktCourt` already *is* that arbiter: a contract convenes a
panel, and the verdict is delivered programmatically via `onVerdict(escrowRef, verdict)` — no human,
no UI, no wallet prompt. This phase makes that the headline product: **Verdikt is the settlement court
for the autonomous agent economy.** Escrow/Insurance were the on-ramp; A2A is the destination.

- [x] **`src/VerdiktAgentEscrow.sol` — machine-native escrow.** Built on `feat/agent-escrow` (commit
  `3dd373f`). Both counterparties may be contracts/agents; lifecycle is fully code-callable and
  settlement routes through `onVerdict`. Key change vs `VerdiktEscrow`: **pull-payment settlement**
  (credit + `withdraw()`) so a non-receiving counterparty can't brick the court callback or strand the
  honest party. 12 tests incl. `test_settles_toNonReceivingAgent_doesNotBrick`; full suite now 47/47.
  *Remaining for full agent-operability: a deploy script + the autonomous two-agent demo (below).*
- [ ] **Agent-initiated disputes.** Expose `openCase(escrowRef, evidence)` as a first-class agent
  action with **structured, machine-generated evidence** (a documented JSON-in-string schema the
  agent assembles from on-chain state / its own logs), so panels judge data an agent produced — not
  a human-typed paragraph. Validate `allowedValues` determinism still holds on structured input.
- [ ] **A2A SDK / template.** A documented `IVerdiktConsumer` starter (the verified surface:
  `onVerdict(uint256,Verdict)` + `quoteOpen`/`quoteAppeal`/`getCase`) plus an off-chain agent helper
  that builds evidence, quotes the fee, and opens a case in <50 lines. This is the adoption flywheel:
  any agent framework can wire in Verdikt as its dispute backend.
- [ ] **Reference integration:** stand up two demo agents that strike a deal, one defaults, the other
  opens a case, the panel rules, and the loser's stake is slashed — all autonomous. This is the demo
  that tells the Somnia story better than any escrow UI.
- [ ] **ERC-20 settlement.** Lift the "native STT only" v1 limit so agents settle real stablecoin
  value — parametrize deals/stakes by token across the consumers and the quoting path.

**Exit criteria:** a fully autonomous agent-vs-agent dispute settles on Shannon with no human action
at any step, and an external agent integrates via the SDK.

---

## Phase 4 — Judgment-as-an-oracle (the consumer network + precedent)

Reframe the category. Oracles report *facts* (price, weather); **Verdikt reports *verdicts*** —
"was this delivered as described," "did this proposal violate the charter," "is this attestation
valid." A subjective-truth oracle any protocol can query. The goal: every dispute-bearing protocol on
the chain routes through one shared Court.

- [ ] **Onboard verticals as consumers**, each a thin `IVerdiktConsumer` over the same Court:
  prediction-market resolution (Somnia's own markets), parametric insurance (already have it),
  DAO grant clawbacks, gig/freelance milestone release, content/moderation appeals. "3 consumers" was
  thinking small — the target is *N protocols, one court*.
- [ ] **The precedent layer (the moat).** Verdicts already emit on-chain receipts
  (`agents.somnia.network/receipts/<id>`). Make them **citable**: index every ruling into a queryable
  body of machine-generated case law, and let evidence reference prior `caseId`s so later panels can
  weigh precedent. No competing arbiter has on-chain, AI-authored, citable case law.
- [ ] **Richer verdict types** beyond `PAYEE/PAYER/SPLIT` (e.g. graded SPLIT %) where `allowedValues`
  determinism still holds — validate convergence before shipping.
- [ ] **Observability:** subgraph/indexer for cases, verdicts, appeals, slashes, and precedent
  citations; a public "case law" dashboard.

**Exit criteria:** 3+ live verticals on one shared Court, a queryable precedent index, and at least one
panel that cites a prior case.

---

## Phase 5 — Infrastructure & moonshot (decentralize, then disappear into the stack)

The end state: Verdikt is invisible infrastructure — the default subjective-dispute settlement layer
an agentic chain just *has*, the way it has price oracles.

- [ ] **Mainnet + audit:** swap to mainnet `IAgentRequester` (`0x5E5205...`, chain 5031), parametrize
  network in deploy scripts, gate launch on a real external audit of Court + one consumer.
- [ ] **Remove owner trust:** migrate Court admin (`setAgentId`/`setPerAgentPrice`/`setAppealWindow`/
  `setRequestTimeout`/`sweep`) to a timelock/multisig, then toward governance.
- [ ] **Arbitration marketplace:** competing court configs (panel size, consensus type, agent models)
  that consumers/agents choose by SLA and price — Verdikt as a meta-layer over many juries.
- [ ] **Cross-domain reputation:** portable, receipt-backed history of how each party (human *or*
  agent) behaves across disputes — an agent's litigation record becomes a credential.
- [ ] **Economic design:** treasury-cut calibration, anti-frivolous-appeal stake sizing backed by
  simulation, and a sustainable fee model for the Court itself. Governance + token over parameters and
  treasury *only if* it earns its place (per "no speculative generality").
- [ ] **Beyond Somnia:** generalize the receipt/consensus pattern to any chain with verifiable agent
  inference — Verdikt as the portable arbitration standard for the agent economy at large.

**Exit criteria:** audited, non-owner-controlled Court on mainnet that multiple external protocols and
autonomous agents depend on as shared infrastructure.

---

## Critical path (do these in order)

```
LLM_AGENT_ID (🟡 user)  →  determinism gate  →  Shannon deploy  →  live demo  →  submit
        Phase 0 ───────────────────────────────────────────────────  Phase 1
```

Everything else is parallelizable once Phase 0–1 land. **The single highest-leverage action right now
is registering the agent id** — it unblocks the proof the entire project depends on.
