# Verdikt accuracy benchmark

Measures how often a live Verdikt panel agrees with the "correct" verdict a fair human arbitrator
would reach, plus how often the panel converges byte-identically. This is the credibility artifact:
"AI judge" → "measurably agrees with human rulings X% of the time, with full receipts."

## What it does

`benchmark-cases.json` holds curated disputes, each with a defensible `expected` label
(PAYEE / PAYER / SPLIT). `run-benchmark.mjs` fires each through the **hardened 3-label prompt**
(the deployed `InjectionProbe`, which replicates `VerdiktCourt._buildPayload`'s production prompt),
then scores the panel's majority verdict against `expected` and reports per-outcome agreement +
convergence.

SPLIT cases are inherently the most debatable; read per-outcome accuracy with that in mind.

## Run

```bash
cd script
npm install                      # viem + dotenv (once)
node run-benchmark.mjs --dry     # preview the dataset, spends nothing
node run-benchmark.mjs <INJECTION_PROBE_ADDR>            # full run (~0.4 STT/case)
node run-benchmark.mjs <ADDR> --limit 4                  # cheaper subset
node run-benchmark.mjs <ADDR> --panel 9                  # larger panel
```

Reads `PRIVATE_KEY` / `SHANNON_RPC` / `LLM_AGENT_ID` from `../.env`. The InjectionProbe address is
recorded in `deployments/shannon.json` under `injectionGate.probe`.
