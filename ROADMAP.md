# Verdikt — Roadmap

**Vision:** Verdikt becomes the **settlement court for the autonomous agent economy** — the neutral
arbiter that on-chain agents need but don't have. Autonomous agents can transact, but they can't sue
each other; on a chain whose entire thesis is agents (Somnia's Agentic L1), subjective disputes have
no judge. `VerdiktCourt` is that judge: a reusable AI-jury primitive that _any contract or agent_ can
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

The whole pitch rests on one unproven claim: _a validator subcommittee converges byte-identically on an
LLM verdict._ Until that's shown live, everything else is theory. This phase turns theory into a
working on-chain demo.

- [x] **LLM Inference agent ID obtained + set** in `.env`: `12847293847561029384` (pre-deployed
      Phase-1 base agent from the testnet explorer; no registration/API key). Resolved live on Shannon —
      the Court holds it and panels dispatch against it.
- [x] **Fund the deployer** — confirmed `0xFDc753d1b3967653bC8Dcc394a38FBf3ea5a6a58` holds **100 STT**
      on Shannon; covers all deploys (~0.10 STT) + panel fees (5 ≈ 0.40, 9 ≈ 0.72) many times over.
- [x] **Dry-run all scripts** — `forge build` green (lint warnings only); `Deploy`, `ProbeDeploy`,
      `DeployInsurance` all `SIMULATION COMPLETE` against live Shannon (chain 50312) with placeholder env,
      no broadcast. Deploy ≈ 0.058 STT, Probe ≈ 0.016, Insurance ≈ 0.030. `script/` + `keeper/` deps
      installed. **Only `LLM_AGENT_ID` remains to go live.**
- [x] **Run the determinism gate — PASS.** Probe `0xDCF1829FB93d2d3d725E4e78e5C958fb947C02bb`,
      panel 5 → **PAYEE 5/5 (100%), byte-identical convergence** in ~11s (requestId 3486438, fire tx
      `0xdbbe4fbb…aa869e`, fee 0.40 STT). The premise the whole design rests on is proven live. Capture a
      screenshot of the histogram for the deck/submission.
  - ⚠️ **Gas gotcha discovered:** Somnia meters _contract deployment_ far more expensively than
    mainnet, so `eth_estimateGas` under-reports and forge's default limit OOGs (tx fails with
    `gasUsed == gasLimit`). Deploy with an explicit high `--gas-limit` (probe needed >8M, succeeded at
    20M) or a large `--gas-estimate-multiplier`. Function calls (e.g. `fire`) estimate fine.
- [x] **Deploy the stack to Shannon** (via `forge create --gas-limit 50000000`; addresses in
      `deployments/shannon.json`). Court `0xd427dcb1…66ee`, Escrow `0xED2cBf87…6Ea6`, Insurance
      `0xEA462e02…46Da4`. Agent id set in the Court constructor; wiring verified on-chain.
- [x] **End-to-end live dispute — DONE on Shannon.** Deal #1 (0.01 STT): `createDeal → dispute →
live 5-agent panel → PAYER verdict → finalize → buyer refunded`. Deal status Settled, case Final,
      escrow drained to 0. The full no-human-in-the-loop lifecycle, proven on-chain. (Appeal-window
      shortened to 60s via `setAppealWindow` for the demo.) **Still optional:** drive one appeal that
      escalates the panel 5 → 9 to showcase the staked-appeal/slash path live.

**Exit criteria:** a real Shannon tx hash for a settled dispute + an agent receipt URL we can show on
screen. This is the hackathon's killer proof point.

---

## Phase 1 — Demo polish & submission-grade artifacts

Make the win legible to judges in under 3 minutes.

- [x] **Wire the UI to live addresses.** `ui/index.html` now defaults Court/Escrow to the deployed
      addresses (DEPLOYED const); the per-case "View receipt" link (`agents.somnia.network/receipts/<id>`)
      was already present.
- [~] **Run the keeper live.** `keeper/keeper.mjs` wired via `.env` (COURT/ESCROW/START_BLOCK) and
  **redesigned for Somnia** — the original single wide `eth_getLogs` is rejected (Somnia caps the range
  and runs ~20 blocks/s), so it now uses a **persistent cursor + chunked scan + watch-set**. Runs
  cleanly and finalize/release logic verified; reliable live auto-finalize is gated on a more robust
  RPC endpoint (`api.infra` getLogs intermittently times out under load). finalize itself proven —
  4 live disputes settled (manually + by direct `finalize`).
- [ ] **Record a 2–3 min demo video** of the full loop, with the determinism histogram + a receipt on
      screen. _(Needs a screen — yours.)_
- [x] **Update README + DECK** with the live addresses, determinism PASS, gas note, and the panel-9
      appeal/testnet-validator limitation.
- [ ] **Housekeeping:** decide `DECK.html` fate (commit the rendered deck or add to `.gitignore`);
      confirm `verdikt.gudman.xyz` is actually live against `deploy/nginx-verdikt.gudman.xyz.conf`.
- [ ] **Submit** — only after explicit user approval (per standing rule).

**Exit criteria:** submission package = repo + live demo URL + video + on-chain proof. Hackathon-ready.

---

## Phase 2 — Harden the protocol (post-win, toward credibility)

Turn hackathon code into something defensible.

- [x] **Confirmed the unknowns** (researcher agent, verified):
  - `createAdvancedRequest` `timeout` is in **seconds** (300 = 5 min; operator default 15 min) — fine.
  - Shannon supports **Cancun** (PUSH0/MCOPY/TLOAD/TSTORE verified live on-chain) → bumped
    `evm_version = "paris"` → `"cancun"`. Full suite re-run green (60/60). Caveat: explorer
    verification defaults to `paris` — match the setting when verifying.
  - Validator subcommittee **effective cap is ~6** on Shannon (docs ceiling 10) — this is why the
    panel-9 appeal reverted. Keep trial panels ≤ 5.
- [x] **Internal security review** — full audit of all 4 contracts → [`SECURITY.md`](SECURITY.md).
      Top finding: Escrow/Insurance push-payments can be bricked by a reverting recipient; the shipped
      fix/reference is `VerdiktAgentEscrow`'s pull-payment ledger. 10 findings logged with v2 remediation.
- [x] **Invariant & fuzz tests** — [`test/Invariant.t.sol`](test/Invariant.t.sol): fund conservation,
      solvency, stake-slash exactness (`toWinner + treasuryCut == stake`), `_split` sums, no-double-settle.
- [ ] **Per-request fee accounting** + **push→pull port to Escrow/Insurance** + appeal-deadline
      snapshot — the contract changes from the audit. Deferred to a v2 redeploy (breaking; the live
      testnet contracts are the push-payment v1). Tracked in `SECURITY.md`.

**Exit criteria:** clean internal review ✅, invariant suite green ✅, "Known simplifications" resolved ✅.
Contract remediations are scoped for v2 (redeploy) per `SECURITY.md`.

---

## Phase 3 — The Agent-to-Agent Court (the flagship thesis)

**Autonomous agents can transact on-chain, but they cannot sue each other.** When an agent-to-agent
deal goes wrong, there is no neutral arbiter — and a chain whose entire thesis is autonomous agents
(Somnia's Agentic L1) needs one. `VerdiktCourt` already _is_ that arbiter: a contract convenes a
panel, and the verdict is delivered programmatically via `onVerdict(escrowRef, verdict)` — no human,
no UI, no wallet prompt. This phase makes that the headline product: **Verdikt is the settlement court
for the autonomous agent economy.** Escrow/Insurance were the on-ramp; A2A is the destination.

- [x] **`src/VerdiktAgentEscrow.sol` — machine-native escrow.** Built on `feat/agent-escrow` (commit
      `3dd373f`). Both counterparties may be contracts/agents; lifecycle is fully code-callable and
      settlement routes through `onVerdict`. Key change vs `VerdiktEscrow`: **pull-payment settlement**
      (credit + `withdraw()`) so a non-receiving counterparty can't brick the court callback or strand the
      honest party. 12 tests incl. `test_settles_toNonReceivingAgent_doesNotBrick`; full suite now 47/47.
      _Remaining for full agent-operability: a deploy script + the autonomous two-agent demo (below)._
- [x] **Agent-initiated disputes / structured evidence.** [`src/lib/EvidenceLib.sol`](src/lib/EvidenceLib.sol)
      — a deterministic formatter that turns structured fields (dealId, parties, amount, deadline, claim,
      `priorCaseId` for precedent) into a byte-identical evidence string an agent assembles from on-chain
      state. Schema in [`sdk/evidence-schema.md`](sdk/evidence-schema.md); 5 tests incl. byte-exact output +
      end-to-end settlement. Note: doesn't change `allowedValues`, so determinism/consensus is unaffected.
- [x] **A2A SDK / template** — [`sdk/README.md`](sdk/README.md): "integrate the court in <50 lines",
      minimal `IVerdiktConsumer` skeleton + lifecycle, all real signatures, pull-payment guidance.
- [x] **Reference integration** — [`test/AgentToAgentDemo.t.sol`](test/AgentToAgentDemo.t.sol): two
      contract agents (BuyerAgent/SellerAgent) settle a dispute with **no EOA in the loop**, plus a
      `RevertingSellerAgent` proving a bad counterparty can't brick settlement. 2 tests, green.
- [x] **ERC-20 settlement.** [`src/VerdiktTokenEscrow.sol`](src/VerdiktTokenEscrow.sol) — a
      token-denominated, pull-payment escrow: deal value + appeal stakes are an ERC-20 (constructor
      `(court, treasury, token)`), while court agent fees stay native STT. Settlement credits a token
      ledger; parties `withdraw()` tokens. 9 tests (PAYEE/PAYER/SPLIT, appeal slash/return, exact stake
      conservation). "Agents settle real stablecoin value" — done.

**Exit criteria:** ✅ a fully autonomous agent-vs-agent dispute settles (in tests/mock; on Shannon for
the native path) with no human action, and an external agent can integrate via the SDK. **Phase 3
complete** (full suite 74/74). The token + agent escrows are built/tested but not yet deployed to Shannon.

---

## Phase 4 — Judgment-as-an-oracle (the consumer network + precedent)

Reframe the category. Oracles report _facts_ (price, weather); **Verdikt reports _verdicts_** —
"was this delivered as described," "did this proposal violate the charter," "is this attestation
valid." A subjective-truth oracle any protocol can query. The goal: every dispute-bearing protocol on
the chain routes through one shared Court.

- [x] **Onboard verticals as consumers.** Now **6 consumers over one Court**: `VerdiktEscrow`,
      `VerdiktInsurance`, `VerdiktAgentEscrow`, `VerdiktTokenEscrow`, plus new
      [`VerdiktGrantClawback`](src/VerdiktGrantClawback.sol) (DAO grant: PAYER = clawback to the DAO) and
      [`VerdiktMilestone`](src/VerdiktMilestone.sol) (freelance milestone). Each a thin pull-payment
      `IVerdiktConsumer`. "N protocols, one court" — demonstrated. (14 new tests.)
- [x] **The precedent layer (the moat).** [`src/VerdiktRegistry.sol`](src/VerdiktRegistry.sol) — a
      permissionless, append-only index of FINAL rulings: `record(caseId, topic)` reads `court.getCase`,
      stores the verdict + receiptId, and indexes by topic/consumer. Queryable case law that
      `EvidenceLib.priorCaseId` cites. 7 tests.
- [ ] **Richer verdict types** beyond `PAYEE/PAYER/SPLIT` (e.g. graded SPLIT %) — **deferred**: it
      changes the Court's core `allowedValues`/verdict space and the convergence claim needs _live_
      determinism validation (can't verify offline). Scoped for a v2 with a live re-run.
- [x] **Observability.** [`indexer/index.mjs`](indexer/index.mjs) — chunk-scans Court events
      (VerdictReached/Appealed/CaseFinalized) into a `caselaw.json` snapshot (cursor-based, Somnia-safe);
      [`ui/caselaw.html`](ui/caselaw.html) — a case-law dashboard with verdict badges + receipt links.

**Exit criteria:** ✅ 6 consumers on one shared Court, ✅ a queryable precedent index + dashboard.
**Phase 4 complete** (full suite 95/95). Richer verdict types deferred (needs live validation).
The new Phase 3/4 contracts are built/tested but not yet deployed to Shannon.

---

## Phase 5 — Infrastructure & moonshot (decentralize, then disappear into the stack)

The end state: Verdikt is invisible infrastructure — the default subjective-dispute settlement layer
an agentic chain just _has_, the way it has price oracles.

- [~] **Mainnet + audit:** deploy scripts already take the platform via `SOMNIA_PLATFORM` env
  (set the mainnet `IAgentRequester` `0x5E5205…`, chain 5031). The external audit is third-party and
  out of scope here; the internal audit + invariant suite ([`SECURITY.md`](SECURITY.md),
  `test/Invariant.t.sol`) is the gate we control. New Phase 3–5 contracts not yet deployed.
- [x] **Remove owner trust.** [`src/VerdiktTimelock.sol`](src/VerdiktTimelock.sol) — a generic
      delayed-execution governor (queue→delay→execute, MIN/MAX delay) that can own the Court; plus a
      **2-step `transferOwnership`/`acceptOwnership`** added to `VerdiktCourt` so a live deployment can
      migrate admin to the timelock. 11 tests (full migration + governed `setAppealWindow`).
- [x] **Arbitration marketplace.** [`src/VerdiktCourtRegistry.sol`](src/VerdiktCourtRegistry.sol) —
      operators list competing courts (name, model, SLA, live `quoteOpen`); `cheapest()` shops by live
      price. Verdikt as a meta-layer over many juries. 15 tests.
- [x] **Cross-domain reputation.** [`src/VerdiktReputation.sol`](src/VerdiktReputation.sol) — a
      portable, court-verified litigation record per party (wins/losses/splits, `scoreOf`); an agent's
      dispute history becomes a credential. 7 tests.
- [x] **Economic design.** [`ECONOMICS.md`](ECONOMICS.md) — fee model, anti-frivolous-appeal
      break-even math (`p* = (f+S)/(A+S)`, worked table), treasury-cut calibration, and a reasoned
      "no token yet" argument with the conditions under which one would earn its place.
- [x] **Beyond Somnia.** [`PORTABILITY.md`](PORTABILITY.md) — separates the 4-call Somnia surface from
      the chain-agnostic core (~95%), proposes an `IInferencePlatform` adapter so the Court runs on any
      chain with verifiable agent inference, and a 7-item portability checklist.

**Exit criteria:** ✅ governance path (timelock), ✅ marketplace, ✅ reputation, ✅ econ + portability
design. **Phase 5 substantially complete** (full suite 141/141). Remaining: external audit + mainnet
deploy (require funded mainnet key + a real auditor); richer verdict types from Phase 4 (live validation).

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
