# Determinism gate — driver notes

`run-determinism-gate.mjs` is the one-shot operator script invoked from the
top-level README's "Determinism gate" section. This file documents what the
script actually does and how to read its output.

## What it does

1. Loads `PRIVATE_KEY`, `SHANNON_RPC`, `LLM_AGENT_ID` from `../.env`.
2. Reads `platform()` from the deployed `DeterminismProbe`.
3. Calls `platform.getAdvancedRequestDeposit(panel)` on-chain and computes
   the exact fee:

       fee = getAdvancedRequestDeposit(panel) + 0.07 STT * panel

   This mirrors `VerdiktCourt._depositFor` (see `src/VerdiktCourt.sol`).
4. Sends `fire(evidence, panel)` with that exact `value`.
5. Polls `getResults()` every 10 s for up to 5 minutes.
6. Prints a verdict-frequency histogram and a PASS / PARTIAL / FAIL line.

## Usage

```bash
cd script
npm install
node run-determinism-gate.mjs <PROBE_ADDR> [evidence] [panel]
```

- `<PROBE_ADDR>` — printed by `ProbeDeploy` after `forge script ... --broadcast`.
- `evidence` — optional; defaults to a tracking-dispute string.
- `panel` — optional; defaults to 5.

Exit codes: `0` results landed, `1` no results / revert, `2` config error.

## Interpreting the histogram

```
PAYER     5/5  100%  ########################
```

- `PASS` — top label count equals panel size (byte-identical convergence).
- `PARTIAL` — top label has strict majority but is not unanimous; the design
  still settles, but flag this for review.
- `FAIL` — no majority. Tighten the prompt: restrict `allowedValues` to
  `["PAYEE", "PAYER"]` and/or set `chainOfThought=false` in
  `DeterminismProbe.fire`, redeploy, and re-run.

## Why this isn't in `script/Probe.s.sol`

Forge scripts can't sleep-and-poll across blocks; the response lands in a
later block via `handleResponse`. A small Node driver is the simplest correct
solution.
