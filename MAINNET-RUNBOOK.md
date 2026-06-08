# Verdikt — Mainnet Deploy Runbook

Step-by-step runbook to deploy Verdikt to **Somnia mainnet (chain 5031)**. The deploy mechanics
mirror [`script/Deploy.s.sol`](script/Deploy.s.sol) and
[`script/DeployInsurance.s.sol`](script/DeployInsurance.s.sol); the only required change is the
network env (platform, RPC, agent id) plus the Somnia gas handling baked in below.

> **Do not run any of this until the pre-deploy checklist passes.** Verdikt is live on Shannon
> testnet only and has had an internal review, not an external audit (`SECURITY.md`).

**Network facts (verified in-repo):**
- Mainnet `IAgentRequester` platform: `0x5E5205CF39E766118C01636bED000A54D93163E6`, chain **5031**
  — confirmed in `src/interfaces/IAgentRequester.sol`, `README.md`, and `ROADMAP.md`.
- Testnet (for reference): `0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776`, chain 50312.
- Mainnet RPC URL: **TODO** — not present in repo; get the canonical URL from
  docs.somnia.network and add it as an rpc endpoint (see step 1).

---

## Prerequisites

- A **funded mainnet deployer key** (native gas token on chain 5031). The same address becomes
  the default `TREASURY` and the Court owner unless overridden.
- A **real `LLM_AGENT_ID` registered on mainnet** at agents.somnia.network. The testnet agent id
  (`12847293847561029384` in `deployments/shannon.json`) is **not** valid on mainnet — register
  and use the mainnet one. **TODO: obtain mainnet agent id.**
- Foundry installed; this repo building clean (`forge build`) on `solc 0.8.24`, `evm_version cancun`.
- Decide the **TREASURY** address (slashed-stake cut recipient) and the **governance owner** for
  the Court — ideally `VerdiktTimelock`, not a single EOA (see wiring step 5).
- Confirm Cancun opcode support on mainnet. Shannon supports it (foundry.toml note); **verify the
  same holds on chain 5031 — TODO**. If not, set `evm_version` accordingly before deploying.

---

## Pre-deploy checklist (gate — all must be true)

- [ ] External third-party audit complete; all Critical/High findings remediated and re-tested.
- [ ] Bug bounty run (or scheduled to open at launch) — see [`BUG-BOUNTY.md`](BUG-BOUNTY.md).
- [ ] `forge test` green (documented 230/230) on the exact commit being deployed.
- [ ] **Determinism re-gated on mainnet validators**, not just Shannon. Run the determinism +
      graded-determinism + abstention + injection gates against the mainnet platform and confirm
      byte-identical convergence on the production validator set (the appeal panel of 9 needs ≥ 9
      validators — verify mainnet has them, since Shannon could not run it live).
- [ ] **Prompt + model pinned.** Record the exact governed prompt version and the LLM model the
      mainnet agent runs. Re-run the gates if the prompt or label set changes after this point.
- [ ] Config decided and recorded: `gradedSplit` on/off, `allowAbstention` on/off, `appealWindow`
      (the demo used 60s — set a production value), `requestTimeout`, per-agent price.
- [ ] Governance plan decided: deploy + own via `VerdiktTimelock`, with the timelock delay set.
- [ ] Treasury address confirmed.

---

## Step 1 — Configure the mainnet env

`.env` (never commit it — see `.env.example`):

```bash
PRIVATE_KEY=0x<funded mainnet deployer key>
LLM_AGENT_ID=<mainnet agent id>                                  # TODO
SOMNIA_PLATFORM=0x5E5205CF39E766118C01636bED000A54D93163E6       # mainnet AgentRequester (chain 5031)
TREASURY=0x<treasury address>                                    # or omit to default to deployer
MAINNET_RPC=<somnia mainnet rpc url>                             # TODO: from docs.somnia.network
```

`Deploy.s.sol` reads `SOMNIA_PLATFORM` via `vm.envOr(... DEFAULT_PLATFORM)` — the default is the
**testnet** address, so setting `SOMNIA_PLATFORM` to the mainnet platform is **mandatory**.

Add a mainnet rpc endpoint to `foundry.toml` (repo currently only defines `shannon`):

```toml
[rpc_endpoints]
shannon = "${SHANNON_RPC}"
mainnet = "${MAINNET_RPC}"
```

---

## Step 2 — Deploy Court + Escrow (with the Somnia gas gotcha)

> **Gas gotcha (from `deployments/shannon.json` notes):** Somnia meters contract *deployment*
> far above mainnet baseline and `eth_estimateGas` under-reports, so a default-limit tx OOGs
> with `gasUsed == gasLimit`. Deploy with an explicit high gas limit (Shannon used **60M**) or a
> large estimate multiplier. State-write calls also need generous limits (~3–5M).

Two options — **`forge create` with an explicit `--gas-limit` is the proven path** (every live
v2/v3/v4 stack in `deployments/shannon.json` was deployed this way; `forge script` estimateGas
under-reports on Somnia).

**Option A — `forge create` (recommended, matches live deploys):**

```bash
# VerdiktCourt(platform, agentId)
forge create src/VerdiktCourt.sol:VerdiktCourt \
  --rpc-url mainnet --private-key $PRIVATE_KEY --broadcast \
  --gas-limit 120000000 \
  --constructor-args 0x5E5205CF39E766118C01636bED000A54D93163E6 <LLM_AGENT_ID>

# VerdiktEscrow(court, treasury)  — court = address printed above
forge create src/VerdiktEscrow.sol:VerdiktEscrow \
  --rpc-url mainnet --private-key $PRIVATE_KEY --broadcast \
  --gas-limit 60000000 \
  --constructor-args <COURT_ADDRESS> <TREASURY_ADDRESS>
```

> The `adaptiveDemo` deploy used `--gas-limit 120M` for the Court and `60M` for the Escrow.
> Start there and adjust if the tx still OOGs.

**Option B — `forge script` (if estimateGas proves sufficient on mainnet):**

```bash
forge script script/Deploy.s.sol --rpc-url mainnet --broadcast \
  --gas-estimate-multiplier 400 --slow
```

`Deploy.s.sol` deploys `VerdiktCourt(platform, agentId)` then `VerdiktEscrow(court, treasury)`
and logs all four values. If it OOGs, fall back to Option A.

---

## Step 3 — Deploy the remaining stack

Deploy what the launch needs (each is independent; the consumers bind to the Court address from
step 2). The other consumers/infra follow the same `forge create` pattern; `VerdiktInsurance`
has a dedicated script:

```bash
# Insurance (script takes COURT_ADDRESS + optional TREASURY)
COURT_ADDRESS=<court> forge script script/DeployInsurance.s.sol \
  --rpc-url mainnet --broadcast --gas-estimate-multiplier 400 --slow
```

For the rest — `VerdiktRegistry`, `VerdiktReputation`, `VerdiktAttestationRegistry`,
`VerdiktCourtRegistry`, `VerdiktMarketplace`, `VerdiktKeeperBounty`, `VerdiktTimelock`, and the
extra consumers (`VerdiktAgentEscrow`, `VerdiktTokenEscrow`, `VerdiktGrantClawback`,
`VerdiktMilestone`) — use `forge create` with the constructor args each header documents and the
high `--gas-limit`. **Record every deployed address** in a `deployments/mainnet.json` mirroring
`deployments/shannon.json`. **TODO: create `deployments/mainnet.json`.**

> Constructor args vary per contract (Court+treasury, token address for TokenEscrow, platform for
> the marketplace stake check, timelock admin+delay, etc.). Read each `src/*.sol` constructor
> before deploying — do not assume.

---

## Step 4 — Configure the Court

Apply the config decided in the pre-deploy checklist (owner-only setters on `VerdiktCourt`):

- [ ] `publishPrompt(...)` the audited prompt, then `setActivePromptVersion(...)` to it.
- [ ] `setAttestationRegistry(<registry>)` if verifiable evidence is enabled at launch.
- [ ] `setGradedSplit(<bool>)` and `setAllowAbstention(<bool>)` per the decided config.
- [ ] `setAppealWindow(<seconds>)` to the production value (NOT the 60s demo window).
- [ ] `setRequestTimeout(...)` and per-agent price if changing from defaults.

Each state-write call needs a generous gas limit (~3–5M; see the gas note).

---

## Step 5 — Wire and verify integrations

- [ ] **Escrow.court / consumer.court → mainnet Court.** Confirm each consumer points at the Court
      from step 2 (the live check pattern is `Escrow.court() == Court`, see
      `deployments/shannon.json` `wiringVerified`).
- [ ] **Register the Court** in `VerdiktCourtRegistry` (`list(...)`) so discovery / `cheapest()`
      can find it; confirm `quoteOpen()` succeeds.
- [ ] **Stake the Court** in `VerdiktMarketplace` if launching the economic layer.
- [ ] **Register attestors** in `VerdiktAttestationRegistry` if used.
- [ ] **Transfer Court ownership to `VerdiktTimelock`** via the 2-step flow:
      `transferOwnership(timelock)` then the timelock `acceptOwnership()` — removing single-key
      owner trust (this is the gap noted for the v1 Shannon Court).
- [ ] **Verify all contracts on the mainnet explorer.** Use `evm_version` matching the deploy
      (`cancun`) — the explorer may default to `paris` (foundry.toml note), which fails
      verification.

---

## Step 6 — Post-deploy verification checklist

- [ ] Read back Court config on-chain: `quoteOpen()`, `gradedSplit`, `allowAbstention`,
      `appealWindow`, `activePromptVersion`, `attestationRegistry`, `owner` (== timelock).
- [ ] Confirm each consumer's `court()` and `treasury()` are correct.
- [ ] Run **one real end-to-end dispute** with small value:
      `createDeal → dispute → panel verdict → finalize → withdraw`, and confirm byte-identical
      panel convergence and correct pull-payment settlement.
- [ ] Confirm the verdict's prompt-version snapshot matches the active version.
- [ ] Confirm the precedent ruling was recordable in `VerdiktRegistry` and reputation updated.
- [ ] Confirm `VerdiktKeeperBounty` can finalize a case (liveness path).
- [ ] All addresses recorded in `deployments/mainnet.json`; UI/website/SDK repointed at mainnet.
- [ ] Bug bounty live; security contact published.

---

## Open TODOs (could not verify from the repo)

- Mainnet RPC URL (not in repo).
- Mainnet `LLM_AGENT_ID` (must be registered on mainnet).
- Confirmation that chain 5031 supports Cancun opcodes (Shannon does; mainnet unverified here).
- Whether mainnet has ≥ 9 validators for the appeal panel (Shannon did not, per README).
- `deployments/mainnet.json` and a mainnet `[rpc_endpoints]` entry do not yet exist.
- Production values for `appealWindow`, prices, timelock delay, and the launch config flags.
