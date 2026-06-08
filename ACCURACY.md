# Verdikt — Accuracy (honest version)

This document reports Verdikt's measured arbitration accuracy exactly as recorded, states
the real-money risk that the disagreement implies, and lists the mitigations that actually
exist in the code versus the ones that are still recommended limitations. No vanity numbers.

Sources: `script/benchmark-results.md` and the `accuracyBenchmark` block in
`deployments/shannon.json`.

> Location note: `docs/` is gitignored in this repo, so this file lives at the repository
> root alongside `SECURITY.md`.

---

## The benchmark result, exactly as recorded

- **Setup:** live run on Somnia Shannon, **panel of 5**, hardened **3-label** prompt
  (`PAYEE/PAYER/SPLIT`), InjectionProbe `0xEfac45816518C8090BaB5Aa9D898df3895cB0eD8`.
- **Sample size:** **12** curated disputes (`script/benchmark-cases.json`), each with a
  defensible human-expected verdict.
- **Agreement with human-expected verdict:** **11 / 12 = 92%**.
- **Convergence:** **12 / 12 = 100% byte-identical** (every panel reached unanimous
  consensus).
- **Per-outcome breakdown:** **PAYEE 4/4 · PAYER 4/4 · SPLIT 3/4**.
- **Cost:** ~4.4 STT spent on the run (`deployments/shannon.json`).

Both sources agree on every figure above.

### The one divergent case (#9)

> "Correct item shipped, but arrived 10 days late after the event; item is as described and
> still usable." **Expected SPLIT; the panel ruled PAYEE 5/5** (byte-identical).

Per `script/benchmark-results.md`, this is characterized as a defensible judgment rather than
a clear error — the goods were delivered as described and retain value, so releasing to the
seller is arguable, and whether lateness alone warrants a split is genuinely debatable. That
framing is reasonable, **but for an honest accuracy doc it must still be counted as a
disagreement with the human-expected label.** All three accuracy "misses" risk are in the
SPLIT bucket, which is the inherently debatable tail.

---

## What the 92% actually means: real-money error risk

Verdikt settles real value. The benchmark says that on this curated set, roughly **8% of
disputes (1 in 12) resolved to a label other than the human-expected one.** When the verdict
drives a payout, a wrong-for-this-case label means **money moves to the wrong party.**

Caveats that keep this honest:

- The sample is **small (n=12) and curated**, not a representative real-world distribution.
  92% should be read as "promising on a hand-picked set," not as a population accuracy.
- Disagreement clustered entirely in the **SPLIT** bucket — the exact cases where human
  arbitrators also diverge. The decisive PAYEE/PAYER cases were 8/8.
- "Defensible" is not the same as "correct for the party who lost the money." The error risk
  is real regardless of how reasonable the alternative ruling is.

---

## Mitigations that EXIST in the code

These are implemented and traceable, not aspirational:

- **Stake-backed appeal.** A losing party can `appeal(caseId, newEvidence)` within the
  `appealWindow`; the case is re-tried by a **larger panel** (round 1 = 9 agents,
  `_panelSize`). Consumers (e.g. `VerdiktEscrow`) **slash** the appellant's stake when the
  original verdict is upheld and return it when overturned, so a frivolous appeal is
  economically punished. `SECURITY.md` #12 records that appeal accounting now compares both the
  verdict enum **and** `payeeBps`, so a graded change like `SPLIT25 -> SPLIT75` is correctly
  treated as overturned rather than upheld.
  - Honest caveat: the 9-agent appeal panel exceeds Shannon's validator subcommittee (~6), so
    the appeal escalation is **unit-tested but not run live** (`README.md`).
- **Abstention / safe default.** With `allowAbstention` on, the panel may return
  `UNDECIDABLE` when evidence is genuinely insufficient instead of guessing. All six consumers
  settle `UNDECIDABLE` to the **safe default (refund the payer/depositor)** (`SECURITY.md`
  "Abstention"). Validated live: `abstentionGate` PASS — clear case decided `PAYER 4/4`,
  genuinely-insufficient case abstained `UNDECIDABLE 4/4`, both byte-identical.
- **Graded SPLIT.** `SPLIT25/50/75` lets the panel express partial fault instead of a binary
  win/lose, reducing the cost of the SPLIT-bucket disagreements. `gradedDeterminismGate` PASS
  confirms the graded set still converges byte-identically.
- **Authoritative attested facts.** When an attestation registry is wired, `_verifiedFacts`
  folds in oracle-attested facts ranked above party claims, so verdicts can rest on attested
  truth rather than assertions (live demo in `deployments/shannon.json` `premiumStack`: an attested
  "3 of 4 delivered" fact overrode a false "nothing arrived" claim → `SPLIT75`).

---

## Recommended human-escalation path (documented limitation)

For high-value disputes, **do not treat a single panel verdict as final without a human
backstop.** This is a documented limitation, not an implemented feature:

- Use the stake-backed appeal as the first escalation, then route still-contested or
  above-threshold cases to a human/multisig arbiter before payout.
- The pieces to build this exist around the protocol (permissionless `finalize`, the appeal
  window, the marketplace/challenge layer in `SECURITY.md`), but a value-gated human-review
  hook is **not** wired into the core Court today. Integrators handling material value should
  add one.

---

## Bottom line

On a small curated set, a live Verdikt panel agreed with a fair human arbitrator **92%
(11/12)** and converged **byte-identically 100% (12/12)**, with its single miss confined to
the inherently debatable SPLIT tail. That is a credible, honest result — and it also means an
~8% chance of a money-moving disagreement on these cases, which is why appeal, abstention, and
a human-escalation path for high-value disputes are part of the design rather than optional
polish.
