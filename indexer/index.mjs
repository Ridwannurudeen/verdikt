// SPDX-License-Identifier: MIT
//
// Verdikt indexer — an off-chain observability layer that builds a case-law
// table from VerdiktCourt events on Shannon.
//
// Somnia caps eth_getLogs to a few hundred blocks and runs ~20 blocks/sec, so
// we scan in <=400-block chunks advancing a cursor (mirroring keeper.mjs) rather
// than one wide getLogs. We combine VerdictReached + Appealed + CaseFinalized,
// fill current status/verdict from getCase(caseId), write a caselaw.json
// snapshot, and print a summary table.

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { writeFileSync } from "node:fs";
import { config as loadEnv } from "dotenv";
import { createPublicClient, http, parseAbi } from "viem";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "..", ".env") });

const DEFAULT_RPC = "https://api.infra.testnet.somnia.network/";
const CHUNK = 400n;

// Verdict enum (uint8 on the wire): NONE=0, PAYEE=1, PAYER=2, SPLIT=3.
const VERDICT = ["NONE", "PAYEE", "PAYER", "SPLIT"];
// CaseStatus enum: 0 None, 1 Pending, 2 Ruled, 3 Final, 4 Errored.
const CASE_STATUS = ["None", "Pending", "Ruled", "Final", "Errored"];

// parseAbi has no knowledge of the Verdict enum, so its params are declared as
// their ABI wire type uint8.
const COURT_ABI = parseAbi([
  "function getCase(uint256 caseId) view returns ((address consumer, uint256 escrowRef, uint8 round, uint8 status, uint8 verdict, uint256 receiptId, uint64 rulingTime))",
  "event VerdictReached(uint256 indexed caseId, uint8 verdict, uint8 round, uint256 receiptId)",
  "event Appealed(uint256 indexed caseId, uint8 newRound)",
  "event CaseFinalized(uint256 indexed caseId, uint8 verdict)",
]);

const EVENT = (name) =>
  COURT_ABI.find((f) => f.type === "event" && f.name === name);

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(2);
}

function parseBlock(value, name) {
  if (!value) return 0n;
  try {
    const n = BigInt(value);
    if (n < 0n) die(`${name} must be non-negative`);
    return n;
  } catch {
    die(`${name} must be a non-negative integer; got ${value}`);
  }
}

function parseRpc(value) {
  const rpc = value || DEFAULT_RPC;
  try {
    const url = new URL(rpc);
    if (url.protocol !== "https:" && url.protocol !== "http:") {
      die(`SHANNON_RPC must be http(s); got ${url.protocol}`);
    }
    return rpc;
  } catch {
    die(`SHANNON_RPC is not a valid URL: ${rpc}`);
  }
}

function readEnv() {
  const { SHANNON_RPC, COURT_ADDRESS, START_BLOCK } = process.env;
  if (!COURT_ADDRESS || !/^0x[0-9a-fA-F]{40}$/.test(COURT_ADDRESS)) {
    die("COURT_ADDRESS missing or invalid");
  }
  return {
    rpc: parseRpc(SHANNON_RPC),
    court: COURT_ADDRESS,
    startBlock: parseBlock(START_BLOCK, "START_BLOCK"),
  };
}

// Chunk-scan one event from `fromBlock` to `latest` in <=400-block windows,
// advancing a cursor so a single wide getLogs is never issued.
async function scanEvent(publicClient, court, event, fromBlock, latest) {
  const out = [];
  let cursor = fromBlock;
  while (cursor <= latest) {
    const toBlock = cursor + CHUNK - 1n > latest ? latest : cursor + CHUNK - 1n;
    const logs = await publicClient.getLogs({
      address: court,
      event,
      fromBlock: cursor,
      toBlock,
    });
    for (const log of logs) out.push(log);
    cursor = toBlock + 1n;
  }
  return out;
}

async function main() {
  const cfg = readEnv();
  const publicClient = createPublicClient({ transport: http(cfg.rpc) });

  const latest = await publicClient.getBlockNumber();
  console.log(`verdikt-indexer`);
  console.log(`  rpc        : ${cfg.rpc}`);
  console.log(`  court      : ${cfg.court}`);
  console.log(`  startBlock : ${cfg.startBlock}`);
  console.log(`  latest     : ${latest}`);

  const [reached, appealed, finalized] = await Promise.all([
    scanEvent(
      publicClient,
      cfg.court,
      EVENT("VerdictReached"),
      cfg.startBlock,
      latest,
    ),
    scanEvent(
      publicClient,
      cfg.court,
      EVENT("Appealed"),
      cfg.startBlock,
      latest,
    ),
    scanEvent(
      publicClient,
      cfg.court,
      EVENT("CaseFinalized"),
      cfg.startBlock,
      latest,
    ),
  ]);

  console.log(
    `  events     : ${reached.length} reached, ${appealed.length} appealed, ${finalized.length} finalized`,
  );

  // Build a table keyed by caseId. VerdictReached carries the latest ruling
  // per round; the highest-round entry is the prevailing ruling. Appealed and
  // CaseFinalized set flags.
  const table = new Map();
  const ensure = (caseId) => {
    const key = caseId.toString();
    let row = table.get(key);
    if (!row) {
      row = {
        caseId: key,
        consumer: null,
        escrowRef: null,
        verdict: null,
        round: null,
        receiptId: null,
        rulingTime: null,
        appealed: false,
        finalized: false,
      };
      table.set(key, row);
    }
    return row;
  };

  for (const log of reached) {
    const row = ensure(log.args.caseId);
    const round = Number(log.args.round);
    // Keep the highest-round ruling as the prevailing verdict.
    if (row.round === null || round >= row.round) {
      row.round = round;
      row.verdict =
        VERDICT[Number(log.args.verdict)] ?? String(log.args.verdict);
      row.receiptId = log.args.receiptId.toString();
    }
  }
  for (const log of appealed) ensure(log.args.caseId).appealed = true;
  for (const log of finalized) {
    const row = ensure(log.args.caseId);
    row.finalized = true;
    // CaseFinalized carries the settled verdict.
    row.verdict = VERDICT[Number(log.args.verdict)] ?? String(log.args.verdict);
  }

  // Fill current on-chain status/verdict/consumer/escrowRef from getCase.
  for (const row of table.values()) {
    try {
      const c = await publicClient.readContract({
        address: cfg.court,
        abi: COURT_ABI,
        functionName: "getCase",
        args: [BigInt(row.caseId)],
      });
      row.consumer = c.consumer;
      row.escrowRef = c.escrowRef.toString();
      row.round = Number(c.round);
      row.status = CASE_STATUS[Number(c.status)] ?? String(c.status);
      row.verdict = VERDICT[Number(c.verdict)] ?? row.verdict;
      row.receiptId = c.receiptId > 0n ? c.receiptId.toString() : row.receiptId;
      row.rulingTime = c.rulingTime > 0n ? Number(c.rulingTime) : null;
    } catch (err) {
      console.error(
        `  getCase(${row.caseId}) failed: ${err.shortMessage ?? err.message}`,
      );
    }
  }

  const rulings = [...table.values()].sort((a, b) => {
    const ai = BigInt(a.caseId);
    const bi = BigInt(b.caseId);
    if (ai < bi) return -1;
    if (ai > bi) return 1;
    return 0;
  });

  const outPath = resolve(__dirname, "caselaw.json");
  writeFileSync(outPath, JSON.stringify(rulings, null, 2));
  console.log(`  snapshot   : ${outPath} (${rulings.length} rulings)`);

  if (rulings.length === 0) {
    console.log("\nno cases found in range.");
    return;
  }

  const hist = {};
  for (const r of rulings)
    hist[r.verdict ?? "—"] = (hist[r.verdict ?? "—"] ?? 0) + 1;
  console.log(
    `\nverdict histogram: ${Object.entries(hist)
      .map(([k, v]) => `${k}=${v}`)
      .join("  ")}`,
  );

  const pad = (s, n) => String(s ?? "—").padEnd(n);
  console.log(
    `\n${pad("case", 6)}${pad("verdict", 9)}${pad("round", 7)}${pad("status", 9)}${pad("appealed", 10)}${pad("finalized", 11)}receiptId`,
  );
  console.log("-".repeat(72));
  for (const r of rulings) {
    console.log(
      `${pad(r.caseId, 6)}${pad(r.verdict, 9)}${pad(r.round, 7)}${pad(r.status, 9)}${pad(r.appealed ? "yes" : "no", 10)}${pad(r.finalized ? "yes" : "no", 11)}${r.receiptId ?? "—"}`,
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
