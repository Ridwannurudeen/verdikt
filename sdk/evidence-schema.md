# Verdikt Canonical Evidence Schema

`EvidenceLib` (`src/lib/EvidenceLib.sol`) turns a structured dispute into a single,
deterministic evidence string. An autonomous agent reads the relevant on-chain state,
fills the `Evidence` struct, and calls `format` to get a byte-identical string that it
passes to `court.openCase` / `escrow.dispute` as the `evidence` argument.

Determinism is the point: same fields in → byte-identical string out. The court wraps
this string into a fixed prompt and dispatches it to a Majority panel of inference
agents. A standardized, reproducible input lets every juror — and any later validator
or appeal panel — reason over the exact same bytes.

## Fields

| Field         | Type      | Meaning                                                                 |
|---------------|-----------|-------------------------------------------------------------------------|
| `dealId`      | `uint256` | Escrow deal / case reference the dispute is about.                      |
| `payer`       | `address` | Buyer who funded the escrow (refund recipient on a `PAYER` verdict).    |
| `payee`       | `address` | Seller (release recipient on a `PAYEE` verdict).                        |
| `amount`      | `uint256` | Escrowed amount in wei.                                                  |
| `deliverBy`   | `uint64`  | Delivery deadline (unix seconds), e.g. `Deal.deliverBy`.                |
| `observedAt`  | `uint64`  | When the disputing agent observed the relevant state (unix seconds).    |
| `claim`       | `string`  | The free-text dispute claim (e.g. "delivered late", "never received").  |
| `priorCaseId` | `uint256` | Precedent reference: a prior court caseId to cite, or `0` for none.      |

## Output format

`format` emits newline-separated `key=value` lines in this fixed order:

```
dealId=<dec>
payer=0x<40 hex, lowercase>
payee=0x<40 hex, lowercase>
amount=<dec>
deliverBy=<dec>
observedAt=<dec>
priorCaseId=<dec | "none">
claim=<raw claim string>
```

- Integers render as base-10 with no padding or separators.
- Addresses render as lowercase `0x`-prefixed 40-character hex.
- `priorCaseId` renders as the literal `none` when `0`, otherwise the decimal id.
- `claim` is appended verbatim as the final field so multi-line claims never collide
  with the structured keys above it.

### Worked example

For the struct:

```solidity
EvidenceLib.Evidence({
    dealId: 7,
    payer: 0x00000000000000000000000000000000000000A1,
    payee: 0x00000000000000000000000000000000000000B2,
    amount: 1000000000000000000,
    deliverBy: 1735689600,
    observedAt: 1735693200,
    claim: "goods marked delivered but never arrived",
    priorCaseId: 0
})
```

`format` returns exactly:

```
dealId=7
payer=0x00000000000000000000000000000000000000a1
payee=0x00000000000000000000000000000000000000b2
amount=1000000000000000000
deliverBy=1735689600
observedAt=1735693200
priorCaseId=none
claim=goods marked delivered but never arrived
```

## How an agent populates the fields

1. Read `Deal` from `VerdiktEscrow.deals(dealId)` → `payer`, `payee`, `amount`,
   `deliverBy`.
2. Set `observedAt` to the current block timestamp at decision time.
3. Set `claim` from the agent's own determination of the dispute (the only
   non-derived field).
4. To cite precedent, set `priorCaseId` to an earlier court caseId; otherwise `0`.
5. Call `EvidenceLib.format(e)` and pass the result to `escrow.dispute(dealId, ev)`
   (or `court.openCase(escrowRef, ev)` directly).

## Relationship to the verdict space (unchanged)

Structured evidence only standardizes the **input** the panel reads. It does **not**
touch the court's output constraints. `VerdiktCourt._buildPayload` still pins
`allowedValues = [PAYEE, PAYER, SPLIT]`, so the verdict space — and therefore the
Majority-consensus / determinism guarantees on the result — is exactly as before.
EvidenceLib makes the prompt body reproducible; the court keeps the answer space fixed.
