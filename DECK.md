---
marp: true
theme: default
paginate: true
backgroundColor: "#0e1116"
color: "#e6edf3"
style: |
  section { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; padding: 56px 72px; }
  h1 { color: #79c0ff; font-size: 56px; }
  h2 { color: #79c0ff; font-size: 36px; }
  h3 { color: #e6edf3; font-size: 24px; }
  code { background: #161b22; color: #d2a8ff; padding: 2px 6px; border-radius: 4px; }
  strong { color: #ffa657; }
  ul { line-height: 1.6; }
  hr { border-color: #30363d; }
  footer { color: #7d8590; font-size: 14px; }
footer: github.com/Ridwannurudeen/verdikt — Somnia hackathon, May 2026
---

# Verdikt

**Trustless AI arbitration for on-chain escrow**

Built on Somnia's Agentic L1 · Shannon testnet
`github.com/Ridwannurudeen/verdikt`

---

## On-chain escrow can't handle subjective disputes

- Price feeds and parametric rules can't decide *"was the service delivered as described?"*
- A single off-chain bot is a trust hole the size of the operator
- Human juries (Kleros-style) are slow and uneconomical for small claims
- Most teams ship a 2-of-3 multisig and call it done

The dispute committee that on-chain escrow needs **doesn't exist yet**.

---

## Somnia's Agentic L1 makes AI judgment trust-minimized

A subcommittee of validators each runs the same LLM inference.
Consensus is reached on a **byte-identical** result via `allowedValues`.

That is a juror committee.

We turn it into a **settlement layer**.

---

## VerdiktCourt — a reusable AI-jury primitive

`openCase(evidence)` → panel of **5** LLM agents → Majority verdict (`PAYEE` / `PAYER` / `SPLIT`) → 1-hour appeal window → permissionless `finalize`.

- Per-juror chain-of-thought stored off-chain in the agent **receipt** (`agents.somnia.network/receipts/<id>`)
- Consumer contracts implement `IVerdiktConsumer.onVerdict` and use the court as a settlement layer
- No admin signer · No fallback path · No human in the settlement loop

---

## The novel layer: stake-backed appeals

The losing party can post a stake and force a re-trial with a **9-agent panel and new evidence**.

- Appeal **upheld** → stake slashed to the counterparty (minus configurable treasury cut)
- Appeal **overturned** → stake returned

New evidence is the honest design.
Deterministic inference doesn't randomly change its mind — **only better facts should**.

---

## Two consumers, one primitive

### `VerdiktEscrow`
Two-party deal. Payer funds, payee delivers, anyone can release after the deadline. Appeal stake = 10% of deal.

### `VerdiktInsurance`
Parametric claims-arbitration pool. Funders earn shares; insured pays a 5% premium; pool funders can appeal a `PAYEE` verdict (their capital is at stake); `withdrawPool` is locked while a claim is open.

The court doesn't know what `Escrow` or `Insurance` mean — that's the point.

---

## What ships today

- **3 contracts** (`Court`, `Escrow`, `Insurance`) + 3 interfaces
- **35/35 tests passing** — `forge 1.7.1`, solc 0.8.24, evm_version paris
  - 8 Court · 10 Escrow · 17 Insurance
- **Deploy scripts** for Shannon (`Deploy.s.sol`, `DeployInsurance.s.sol`)
- **Auto-keeper** — Node + viem, watches `VerdictReached` / `Delivered`, drives `finalize` and `release`
- **Demo UI** — single-page HTML, viem from esm.sh, no build step
- **Determinism gate** — probe contract + driver that prints a per-validator histogram
- **🟢 LIVE on Shannon** — Court/Escrow/Insurance deployed; **determinism gate PASSED (PAYEE 5/5, byte-identical)**; a full escrow dispute settled end-to-end by a real on-chain AI panel — no human in the loop

---

## Honest scope

- Shannon testnet only · unaudited hackathon code
- Determinism gate **PASSED live** — panel 5 → PAYEE 5/5, byte-identical convergence
- Appeal escalates the panel 5 → 9; panel 9 exceeds Shannon testnet's validator count, so the staked-appeal path is fully unit-tested and runs live only on a mainnet-scale validator set
- Somnia meters contract deployment well above mainnet — deploy with explicit high gas
- All values in native **STT** — no ERC-20 in v1

### Asks
1. ✅ Panel convergence validated live — what's the testnet validator count (for panel 9 appeals)?
2. Plug in a third consumer — the court is reusable by design

`github.com/Ridwannurudeen/verdikt`
