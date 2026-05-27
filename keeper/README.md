# Verdikt keeper

Single-process polling keeper that drives the two permissionless settlement paths on Shannon:

1. **`VerdiktCourt.finalize(caseId)`** — once a `Ruled` case's appeal window has passed (or it was the final round).
2. **`VerdiktEscrow.release(dealId)`** — once a `Delivered` deal is past its `deliverBy` deadline.

Cases and deals are discovered from `VerdictReached` and `Delivered` event logs starting at `START_BLOCK`. Already-settled ids are cached in-memory; the process is stateless across restarts (it just re-scans).

## Environment

Reads from `../.env` (same file as the deploy + determinism-gate scripts).

| Variable           | Required | Default                                            |
| ------------------ | -------- | -------------------------------------------------- |
| `PRIVATE_KEY`      | yes      | —                                                  |
| `SHANNON_RPC`      | no       | `https://api.infra.testnet.somnia.network/`        |
| `COURT_ADDRESS`    | yes      | —                                                  |
| `ESCROW_ADDRESS`   | yes      | —                                                  |
| `START_BLOCK`      | no       | `0` (earliest)                                     |
| `POLL_INTERVAL_MS` | no       | `30000`                                            |

`PRIVATE_KEY` only needs gas — `finalize` / `release` are non-payable.

## Run

```bash
cd keeper
npm install
npm start
```

Stop with `Ctrl+C` (SIGINT).

## Expected console output

```
verdikt-keeper
  rpc          : https://api.infra.testnet.somnia.network/
  sender       : 0xAbCd...
  court        : 0x1234...
  escrow       : 0x5678...
  startBlock   : 0
  pollInterval : 30000ms
  appealWindow : 3600s
  maxRound     : 1
[idle] no actionable items
[release] dealId=3 tx=0xabc123...
[finalize] caseId=7 tx=0xdef456...
[idle] no actionable items
```

RPC errors are logged and the loop continues; the process only exits on SIGINT or a fatal startup error (bad env, contract read failure).
