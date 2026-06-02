// Verdikt accuracy benchmark.
//
//   node run-benchmark.mjs <PROBE_ADDR> [--limit N] [--panel P] [--dry]
//
// Fires each curated dispute in benchmark-cases.json through a hardened 3-label probe and scores the
// panel's majority verdict against the case's `expected` label, plus byte-identical convergence.
// Reads PRIVATE_KEY / SHANNON_RPC / LLM_AGENT_ID from ../.env. Each fired case costs one panel fee
// (~0.4 STT for panel 5); --dry previews the dataset without spending. Exit 0 on completion.

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import { config as loadEnv } from "dotenv";
import { createPublicClient, createWalletClient, decodeEventLog, fallback, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "..", ".env") });

const POLL_INTERVAL_MS = 10_000;
const POLL_TIMEOUT_MS = 5 * 60_000;
const PER_AGENT_PRICE_WEI = 70_000_000_000_000_000n; // mirrors VerdiktCourt.perAgentPrice (0.07 STT)
const FALLBACK_RPCS = ["https://api.infra.testnet.somnia.network/", "https://dream-rpc.somnia.network/"];

const PROBE_ABI = parseAbi([
  "function fire(string evidence, uint256 panel) payable returns (uint256)",
  "function getResults() view returns (string[])",
  "function lastStatus() view returns (uint8)",
  "function platform() view returns (address)",
  "event Probed(uint256 requestId, uint256 panel)",
]);
const PLATFORM_ABI = parseAbi(["function getAdvancedRequestDeposit(uint256 subcommitteeSize) view returns (uint256)"]);

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(2);
}

function parseArgs() {
  const argv = process.argv.slice(2);
  const probe = argv.find((a) => /^0x[0-9a-fA-F]{40}$/.test(a));
  const flag = (name, def) => {
    const i = argv.indexOf(name);
    return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
  };
  if (!probe && !argv.includes("--dry")) {
    die("usage: node run-benchmark.mjs <PROBE_ADDR> [--limit N] [--panel P] [--dry]");
  }
  return {
    probe,
    limit: Number(flag("--limit", "0")) || 0,
    panel: BigInt(Number(flag("--panel", "5")) || 5),
    dry: argv.includes("--dry"),
  };
}

function loadCases(limit) {
  const data = JSON.parse(readFileSync(resolve(__dirname, "benchmark-cases.json"), "utf8"));
  const cases = limit > 0 ? data.cases.slice(0, limit) : data.cases;
  return cases;
}

function histogram(results) {
  const counts = new Map();
  for (const r of results) counts.set(r, (counts.get(r) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

/// Map a raw label to its base verdict (SPLIT25/50/75 -> SPLIT) for scoring against PAYEE/PAYER/SPLIT.
function baseLabel(label) {
  return label.startsWith("SPLIT") ? "SPLIT" : label;
}

async function main() {
  const args = parseArgs();
  const cases = loadCases(args.limit);

  if (args.dry) {
    const dist = {};
    for (const c of cases) dist[c.expected] = (dist[c.expected] ?? 0) + 1;
    console.log(`benchmark dataset: ${cases.length} cases`);
    console.log(`expected distribution: ${JSON.stringify(dist)}`);
    for (const c of cases) console.log(`  #${c.id} expect ${c.expected.padEnd(5)}  ${c.evidence.slice(0, 80)}...`);
    console.log(`\n(dry run — nothing fired, no STT spent)`);
    return;
  }

  const PRIVATE_KEY = process.env.PRIVATE_KEY;
  if (!PRIVATE_KEY || !/^0x[0-9a-fA-F]{64}$/.test(PRIVATE_KEY)) die("PRIVATE_KEY missing/invalid in ../.env");
  const account = privateKeyToAccount(PRIVATE_KEY);
  const transport = fallback(FALLBACK_RPCS.map((u) => http(u, { timeout: 15_000, retryCount: 3 })));
  const publicClient = createPublicClient({ transport });
  const walletClient = createWalletClient({ account, transport });

  const platform = await publicClient.readContract({ address: args.probe, abi: PROBE_ABI, functionName: "platform" });
  const deposit = await publicClient.readContract({
    address: platform,
    abi: PLATFORM_ABI,
    functionName: "getAdvancedRequestDeposit",
    args: [args.panel],
  });
  const fee = deposit + PER_AGENT_PRICE_WEI * args.panel;

  console.log(`probe   : ${args.probe}`);
  console.log(`sender  : ${account.address}`);
  console.log(`panel   : ${args.panel}   cases: ${cases.length}   est. cost: ~${(Number(fee) / 1e18) * cases.length} STT\n`);

  const rows = [];
  for (const c of cases) {
    process.stdout.write(`#${String(c.id).padStart(2)} expect ${c.expected.padEnd(5)} ... `);
    let results = [];
    try {
      const txHash = await walletClient.writeContract({
        address: args.probe,
        abi: PROBE_ABI,
        functionName: "fire",
        args: [c.evidence, args.panel],
        value: fee,
        chain: null,
      });
      await publicClient.waitForTransactionReceipt({ hash: txHash });
      const deadline = Date.now() + POLL_TIMEOUT_MS;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
        results = await publicClient.readContract({ address: args.probe, abi: PROBE_ABI, functionName: "getResults" });
        if (results.length > 0) break;
      }
    } catch (err) {
      console.log(`ERROR (${err.shortMessage ?? err.message})`);
      rows.push({ ...c, panel: null, converged: false, agree: false });
      continue;
    }
    if (results.length === 0) {
      console.log("NO RESULTS (timeout)");
      rows.push({ ...c, panel: null, converged: false, agree: false });
      continue;
    }
    const rawHist = histogram(results);
    const baseHist = histogram(results.map(baseLabel));
    const panelVerdict = baseHist[0][0];
    const converged = rawHist.length === 1;
    const agree = panelVerdict === c.expected;
    rows.push({ ...c, panel: panelVerdict, raw: rawHist, converged, agree });
    console.log(`panel ${panelVerdict.padEnd(5)} ${agree ? "✓" : "✗"}  conv:${converged ? "Y" : "N"}  [${rawHist.map(([l, n]) => `${l}:${n}`).join(" ")}]`);
  }

  // --- summary --------------------------------------------------------------
  const scored = rows.filter((r) => r.panel !== null);
  const agreed = scored.filter((r) => r.agree).length;
  const conv = scored.filter((r) => r.converged).length;
  console.log(`\n================ BENCHMARK SUMMARY ================`);
  console.log(`scored        : ${scored.length}/${rows.length}`);
  console.log(`agreement     : ${agreed}/${scored.length}  (${((agreed / scored.length) * 100).toFixed(0)}%)`);
  console.log(`convergence   : ${conv}/${scored.length}  (${((conv / scored.length) * 100).toFixed(0)}% byte-identical)`);
  for (const label of ["PAYEE", "PAYER", "SPLIT"]) {
    const sub = scored.filter((r) => r.expected === label);
    if (sub.length === 0) continue;
    const a = sub.filter((r) => r.agree).length;
    console.log(`  expected ${label.padEnd(5)}: ${a}/${sub.length} agreed`);
  }
  const disagreements = scored.filter((r) => !r.agree);
  if (disagreements.length) {
    console.log(`disagreements :`);
    for (const r of disagreements) console.log(`  #${r.id} expected ${r.expected}, panel said ${r.panel}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
