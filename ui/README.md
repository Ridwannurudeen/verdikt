# Verdikt — demo UI

A single-file, no-build browser demo for `VerdiktEscrow` + `VerdiktCourt` on Somnia
Shannon testnet (chain 50312). viem is loaded from esm.sh; everything else is vanilla JS.

## Run

```bash
python -m http.server -d ui 8080
# then open http://localhost:8080
```

Wallet injection (MetaMask / OKX / Rabby / any EIP-1193 provider) generally only
works over `http://` or `https://` — opening `index.html` directly via `file://`
may fail to inject `window.ethereum` on some browsers.

## Prereqs

- An injected EVM wallet on the **Somnia Shannon testnet** (chain id `50312`,
  RPC `https://api.infra.testnet.somnia.network/`). The connect button will add
  the chain to your wallet if it isn't already there.
- Some **STT** from the Somnia faucet (https://testnet.somnia.network).
- A deployed `VerdiktCourt` and `VerdiktEscrow` — paste both addresses into the
  Config panel. They persist in `localStorage` under `verdikt.ui.v1`.

## What it does

1. **Header** — connect wallet, switch/add the Shannon chain.
2. **Config** — RPC URL + Court + Escrow addresses (saved locally).
3. **Create deal** — `escrow.createDeal(payee, deliverBy)` with STT value;
   shows the new `dealId` from the `DealCreated` event.
4. **Manage deal** — load by `dealId`, then the right action buttons appear by
   role + state: mark delivered (payee, Funded), release (payer anytime, or
   anyone after deliverBy on Delivered), dispute (party, fee quoted from
   `court.quoteOpen()`), appeal (losing party — or either on SPLIT — stake +
   `court.quoteAppeal(caseId)`).
5. **Case viewer** — load by `caseId`, decode status/verdict, and link to the
   off-chain juror reasoning at `agents.somnia.network/receipts/<id>`.

## Limits

- No event indexer — direct contract reads only.
- No historical list of deals/cases — you supply the IDs.
- No offline cache; reads run against the configured RPC on every load.
- Contract and receipt links use the Shannon explorer / Somnia agent receipts where available.
