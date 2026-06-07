# Case Study — ServiceSLA: a reference integration as Verdikt's "first user"

> **Honesty note.** This is a **reference deployment**, not an external paying customer. The client,
> the oracle, and the provider in the runs below were driven by the project's own key to demonstrate a
> real integration and to give the precedent ledger genuine, diverse volume. Every transaction, verdict,
> and settlement below is **real and on-chain** on Somnia Shannon — but do not read this as organic
> third-party adoption. Landing a real external integrator is still the #1 growth item.

## What it is

**ServiceSLA** (`src/examples/ServiceSLA.sol`, ~60 lines on `VerdiktConsumerBase`) is a pay-per-period
service agreement whose **SLA-breach disputes are settled by the AI jury** — "judgment as an oracle"
for the agent economy. A client prepays a provider (which may be an autonomous agent) under stated SLA
terms; if the client claims a breach, either party disputes and the panel reads the incident evidence
and rules:

- **PAYEE** → provider met the SLA → fee released to the provider
- **PAYER** → breach → fee refunded to the client
- **SPLIT** → partial service credit
- **UNDECIDABLE** → evidence insufficient → safe default (refund the client)

The entire integration is the `open` / `accept` / `dispute` lifecycle plus a **one-line `_settle`** that
calls `_payeeShareBps(ref, verdict)`. This is the "<50-line integration" claim, exercised for real.

## Live deployment (Somnia Shannon, premium stack)

- **ServiceSLA:** `0xfB2bE585c0776547Ed2e0626F657e9a4AF9e37c9`
- Court `0xeBbA8b849343150e994BEE34778D4D8D38941eDE` · AttestationRegistry `0x9CC2FB982D1a3ED67b827B51Efa7AA43ad3DA5f1` · Registry `0xd1e91c0167a3F5a5aC0F61f86E3883921610261E`
- 4 unit tests (`test/ServiceSLA.t.sol`); full suite 225 passing.

## The two live runs (the interesting part)

Both runs are the **same SLA app, same kind of breach claim**. The only difference is the *evidence*,
and the jury behaved differently — which is exactly the point.

### Run A — unverified claim → the jury abstained
- Client opened a 0.01 STT agreement (99.9% uptime SLA) and disputed, claiming a 6-hour outage.
- **Only the client's own unverified report** was on record (no provider rebuttal, no oracle data).
- Panel of 4 returned **UNDECIDABLE** — it refused to rule on a single uncorroborated claim.
- Settlement: the safe default refunded the client. (Court case #2; recorded as precedent.)
- **What it demonstrates:** abstention as a confidence gate — the jury does not rubber-stamp a claim.

### Run B — oracle-attested outage → decisive refund
- New 0.01 STT agreement. A registered oracle attestor posted a **VERIFIED** fact: independent uptime
  monitoring measured 6h12m of outage, 97.1% vs the 99.9% SLA.
- The client disputed; the court prepended the verified fact above the client's claim.
- Panel of 4 ruled **PAYER (decisive breach)** → client refunded. (Court case #3; recorded.)
- **What it demonstrates:** verifiable-evidence-as-default — corroborated facts turn an abstention into
  a confident verdict.

Together with the escrow run (court case #1: a false "never received" claim overridden by a verified
delivery fact → **PAYEE**), the live precedent ledger now holds **3 real rulings across 2 different
consumer apps** (escrow + SLA) spanning **PAYEE / PAYER / UNDECIDABLE** and exercising **verifiable
evidence, abstention, and model-version pinning** — viewable at `verdikt.gudman.xyz/app/caselaw.html`.

## Honest limitations of this reference integration

- **Single-shot evidence.** `ServiceSLA` (a teaching example) submits only the disputer's evidence at
  dispute time. The production `VerdiktEscrow` uses the **two-sided** pattern
  (`openDispute` → `submitEvidence` → `convene`) so both parties are heard before the panel rules — a
  real SLA product should adopt that, not the single-shot example.
- **Reference, not adoption.** As stated up top, these runs were self-driven. The credibility leap is a
  real external integrator routing real disputes.
- **Inherited trust + accuracy caveats** apply (see `TRUST-MODEL.md`, `ACCURACY.md`).
