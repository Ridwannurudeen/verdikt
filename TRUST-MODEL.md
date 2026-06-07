# Verdikt — Trust Model (honest version)

This document states plainly what Verdikt's AI arbitration **does** and **does not**
guarantee. It is an honesty document: where something is an assumption, a dependency
outside our control, or not yet done, it is marked as such. Every claim is traceable to
the source in this repo (`src/VerdiktCourt.sol`, `SECURITY.md`,
`deployments/shannon.json`).

> Location note: `docs/` is gitignored in this repo, so this file lives at the repository
> root alongside `SECURITY.md`.

---

## 1. What the system actually guarantees

Verdikt's core guarantee is **conditional reproducibility of a verdict**:

> Given a **fixed model**, a **fixed prompt**, and **fixed evidence**, a panel of Somnia
> validator LLM agents converges on a **byte-identical** verdict label, and that label is
> what settles the dispute.

This is verified, not asserted. On Shannon (`deployments/shannon.json`):

- `determinismGate`: PASS — panel of 5, `PAYEE 5/5 (100%)` byte-identical.
- `gradedDeterminismGate`: PASS — panel of 5 over the 5-label graded set, byte-identical
  across three cases (`PAYEE 5/5`, `PAYEE 5/5`, `SPLIT50 5/5`).
- `accuracyBenchmark`: 12/12 (100%) byte-identical convergence across the benchmark set.

The on-chain mechanics that make this hold are in `VerdiktCourt.sol`:

- **Fixed label set.** `_buildPayload` passes an explicit `allowedValues` array
  (`PAYEE/PAYER/SPLIT`, or the graded/abstention supersets) to `inferString`, so juror
  outputs are drawn from a small discrete set — a precondition for byte-identical Majority
  consensus.
- **Deterministic evidence rendering.** `_sanitizeEvidence` strips `<`/`>` deterministically;
  `_verifiedFacts` is read **once at dispatch** so every juror in a panel sees the same
  bytes. The same input produces the same prompt for all jurors.
- **Per-case prompt snapshot.** `_openCase` sets `c.promptVersion = activePromptVersion`,
  and prompt versions are append-only/immutable (`_publishPromptVersion`). A verdict can be
  audited against the exact prompt text that decided it via `promptVersionOf(caseId)` and
  `promptVersion(version)`.
- **Consensus is the platform's job.** The court requests `ConsensusType.Majority` with an
  M-of-N threshold and treats `responses[0]` as the agreed value (`handleVerdict`).

What this guarantee is **not**: it is not a guarantee that the verdict is *correct* (see
[`ACCURACY.md`](ACCURACY.md)), and it is not a guarantee that a verdict will reproduce if
the model behind the agent changes (see §2).

---

## 2. The key dependency and risk: Somnia's validator LLM

The verdict is produced by the LLM run by Somnia's validator subcommittee, addressed by
`agentId` (`VerdiktCourt.agentId`, fetched from `agents.somnia.network`). This is the
single largest dependency in the system, and it is **outside Verdikt's control**:

- **If Somnia changes the underlying model behind `agentId`, past verdicts may not
  reproduce.** A model upgrade, a quantization change, or a different inference backend can
  change the output for the same prompt + evidence. Byte-identical determinism is a property
  of *a given model*, not a permanent property of `agentId`.
- **Verdikt cannot control Somnia's model lifecycle.** We pin which agent id decided each case
  (`modelOf`), but we do not — and cannot — version or freeze the actual LLM Somnia runs behind
  that id. We consume whatever model `agentId` resolves to at request time.

### What Verdikt does to mitigate

- **Prompt versioning IS snapshotted per case.** This is real and in the code
  (`c.promptVersion`, immutable versions). It removes the *prompt* as a source of silent
  drift: a verdict always cites the exact prompt that produced it.
- **Model/agent id IS snapshotted per case.** `_openCase` records `c.modelId = agentId` at
  open time, `_dispatch` sends the request with that per-case snapshot (so an appeal/retry on
  the same case reuses the same model), and `modelOf(caseId)` exposes it on-chain. `setAgentId`
  only affects *new* cases and emits `AgentIdChanged(oldId, newId)`. So every ruling permanently
  records which agent/model id decided it — the model is committed per case, not left to a
  mutable global. The off-chain `receiptId` (per-juror chain-of-thought at
  `agents.somnia.network/receipts/<id>`) remains the forensic anchor for the actual reasoning.
- **Residual, uncontrollable risk.** Pinning the *agent id* records WHICH agent decided a
  case; it cannot freeze the LLM Somnia runs *behind* that id. If Somnia upgrades, quantizes,
  or swaps the model behind a given `agentId`, the same prompt + evidence may stop reproducing
  the same label even though the recorded model id is unchanged. This is outside Verdikt's
  control and is **detected, not prevented**, via the re-runnable gates below.
- **Re-runnable gates.** Determinism is not a one-time claim: the determinism gate
  (`script/run-determinism-gate.mjs`) and the benchmark (`script/run-benchmark.mjs`) can be
  re-run at any time to detect whether the current model still converges and still agrees
  with expectations.

---

## 3. Trusted vs trustless

**Trusted (you must trust these):**

- **Somnia's validator set and its LLM.** They run the inference and reach consensus; the
  court trusts the platform to enforce `ConsensusType.Majority` and to call `handleVerdict`
  only from the platform address (`require(msg.sender == address(platform))`). See
  `SECURITY.md` finding #10 — `responses[0]` is taken as canonical within this trust model.
- **The Court owner / governance.** Owner-only setters control parameters and policy:
  `setAgentId`, `setActivePromptVersion`, `publishPromptVersion`, `setAttestationRegistry`,
  `setAllowAbstention`, `setGradedSplit`, `setPerAgentPrice`, `setAppealWindow`,
  `setRequestTimeout`, `sweep`. A `VerdiktTimelock` exists to take over ownership and make
  governance delayed/transparent — **but per `deployments/shannon.json` the live Court
  ownership is NOT migrated to the timelock** (v1 is pre-ownership-transfer; v2/v4 owner is
  still the deployer EOA). So today owner trust is single-key in practice.
- **Registered attestors** (if an attestation registry is wired). `_verifiedFacts` folds
  their facts in as *authoritative*, above party claims. Per `SECURITY.md`, attested facts
  are **not** sanitized (trusted source), so a compromised-but-registered attestor could post
  a misleading "fact."

**Trustless (no additional trust beyond the chain + the above):**

- **Settlement and payouts.** Consumers settle via pull-payment ledgers (`pending[]` +
  `withdraw()` / `withdrawRefund`), so a reverting recipient cannot brick finalization
  (`SECURITY.md` findings #1, #5, #16). `finalize` is permissionless — a keeper can drive it.
- **Precedent.** `VerdiktRegistry` is a permissionless, append-only index of final rulings.
- **Reputation.** `VerdiktReputation` records win/loss/split history per party.
- **Appeal economics.** Stake-backed appeals slash on an upheld verdict; the staking/slashing
  is on-chain and mechanical.

---

## 4. Attack surface: hardened vs not yet hardened

**Already hardened (with live evidence):**

- **Prompt injection via evidence.** Evidence is fenced in an `<evidence>` block, the system
  prompt marks it untrusted, and `_sanitizeEvidence` strips `<`/`>` so a party cannot forge a
  closing fence to break out and issue instructions. Validated live: `injectionGate` (PASS) —
  evidence whose facts favored PAYER but which embedded an "output PAYEE" instruction was
  ruled `PAYER 5/5`; the panel ignored the injection. Backed by `test/PromptInjection.t.sol`
  (`SECURITY.md` finding #15). **Residual, stated honestly:** this raises the bar; it is not a
  proof. The live gate + red-team suite are the evidence, not a guarantee against all
  injection.
- **Untrusted-evidence fencing / authoritative-fact ordering.** `_verifiedFacts` renders
  attested facts ahead of, and explicitly above, the parties' untrusted claims.

**NOT yet hardened (open risks):**

- **Model substitution (upstream).** Each case now commits the *agent id* that decided it
  (`modelOf`, §2), but there is no defense against Somnia swapping the *LLM behind* a given
  `agentId` — that is detected via the re-runnable gates (§5), not prevented.
- **Attested facts are unsanitized.** A compromised registered attestor can inject a false
  authoritative fact (`SECURITY.md` "Verifiable evidence").
- **Governor risk.** A malicious governor could publish a biased prompt version
  (`publishPromptVersion` + `setActivePromptVersion`). Mitigation is the timelock — which is
  built but **not applied live** (§3).
- **Appeal path not exercised live.** The appeal round requests a 9-agent panel, which exceeds
  Shannon's validator subcommittee (~6), so the staked-appeal escalation is unit-tested but
  has not run end-to-end live (`README.md`, "Live on Shannon").
- **No external audit / bug bounty yet.** This is unaudited hackathon code (`SECURITY.md`,
  "Remaining Production Work").

---

## 5. What would break determinism, and how we'd detect it

| Cause | Effect | Detection |
| --- | --- | --- |
| Somnia changes the model behind `agentId` | Same prompt + evidence may yield a different / non-converging label; past verdicts may not reproduce | Re-run `script/run-determinism-gate.mjs` (expect top label == panel size) and `script/run-benchmark.mjs`; compare to the recorded `determinismGate` / `accuracyBenchmark` in `deployments/shannon.json` |
| Owner re-points `agentId` via `setAgentId` | Only NEW cases use the new model; existing/in-flight cases keep their snapshot | `setAgentId` emits `AgentIdChanged`; each case pins its model via `modelOf` and `_dispatch` uses that snapshot, so historical rulings record (and were decided by) the model they cite |
| Owner activates a new prompt via `setActivePromptVersion` | New cases decided under different "law" | Already auditable: each case pins `promptVersion`; `ActivePromptVersionSet` event is emitted |
| `setGradedSplit` / `setAllowAbstention` toggled | Wider label set can reduce byte-identical convergence | Re-run the matching gate before trusting it live (`gradedDeterminismGate`, `abstentionGate` both PASS today); README explicitly says rerun gates after any label-set change |
| Non-deterministic inference settings | Panel fails to converge | A non-converging panel shows up as PARTIAL/FAIL in the determinism gate histogram; on-chain, a failed Majority routes to `CaseStatus.Errored` and the consumer can `retry` |

The honest summary: **determinism is empirically true today and continuously re-verifiable,
but it rests on a model lifecycle Verdikt does not own.** The mitigations reduce silent drift
(prompt versioning, re-runnable gates) but do not eliminate the dependency.
