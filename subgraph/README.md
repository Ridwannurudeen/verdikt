# Verdikt subgraph

Indexes the Court lifecycle, the precedent registry, and cross-domain reputation into a queryable
GraphQL API — so disputes (and people) can search and cite prior rulings at scale.

This is the **portable indexing spec**: `schema.graphql` (entities), `subgraph.yaml` (manifest mapping
the real contract events), and `src/mapping.ts` (handlers). It is accurate to the on-chain events but
**not yet deployed** — The Graph's hosted/decentralized network does not currently index Somnia
Shannon, so deploying needs a **self-hosted graph-node pointed at a Shannon RPC** (or whatever indexer
Somnia ships). Until then, the live [`ui/explorer.html`](../ui/explorer.html) reads the same data
directly on-chain via viem (no indexer required).

## Deploy (self-hosted graph-node)

```bash
cd subgraph
npm i -g @graphprotocol/graph-cli

# 1. export the ABIs the manifest references
mkdir -p abis
forge inspect VerdiktCourt abi      > abis/VerdiktCourt.json
forge inspect VerdiktRegistry abi   > abis/VerdiktRegistry.json
forge inspect VerdiktReputation abi > abis/VerdiktReputation.json

# 2. fill in subgraph.yaml: each dataSource `source.address` + `startBlock`
#    (from deployments/shannon.json) and the `network` name your graph-node knows.

# 3. generate types, build, deploy to your node
graph codegen
graph build
graph deploy --node http://localhost:8020/ verdikt
```

## Query examples

```graphql
# recent precedent
{ rulings(first: 20, orderBy: recordedAt, orderDirection: desc) { id consumer verdict topic receiptId } }

# all rulings under a topic (topic = keccak256 of e.g. "escrow/non-delivery")
{ rulings(where: { topic: "0x…" }) { id verdict consumer } }

# a party's litigation record
{ party(id: "0x…") { disputes wins losses splits lastCaseId } }
```

## Entities

- **Case** — a dispute's lifecycle (OPENED → RULED → APPEALED → FINAL) with verdict + receipt.
- **Ruling** — a finalized case recorded into the precedent registry (the citable case law).
- **Party** — a wallet's win/loss/split record across all consumers.
