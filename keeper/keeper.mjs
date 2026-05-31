// SPDX-License-Identifier: MIT
//
// Verdikt keeper — drives the two permissionless settlement paths on Shannon:
//
//   1. VerdiktCourt.finalize(caseId)   once a ruling's appeal window has elapsed
//   2. VerdiktEscrow.release(dealId)   once a delivered deal is past deliverBy
//
// Discovery is event-driven (VerdictReached / Delivered) from START_BLOCK,
// and we cache already-settled ids in-memory so re-scans are cheap.

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { createPublicClient, createWalletClient, http, parseAbi } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "..", ".env") });

const DEFAULT_RPC = "https://api.infra.testnet.somnia.network/";
const DEFAULT_POLL_MS = 30_000;
// Somnia caps eth_getLogs to a few hundred blocks, and the chain is fast, so a single
// scan from START_BLOCK to latest is rejected. Scan only a bounded recent window each tick
// (START_BLOCK acts as a floor) — a keeper on a fast chain watches recent blocks anyway.
const MAX_LOG_RANGE = 400n;

const COURT_ABI = parseAbi([
  "function finalize(uint256 caseId)",
  "function appealWindow() view returns (uint64)",
  "function getCase(uint256 caseId) view returns (address consumer, uint256 escrowRef, uint8 round, uint8 status, uint8 verdict, uint256 receiptId, uint64 rulingTime)",
  "function MAX_ROUND() view returns (uint8)",
  "event VerdictReached(uint256 indexed caseId, uint8 verdict, uint8 round, uint256 receiptId)",
]);

const ESCROW_ABI = parseAbi([
  "function release(uint256 dealId)",
  "function deals(uint256) view returns (address payer, address payee, uint256 amount, uint8 status, uint64 deliverBy, uint256 caseId)",
  "event Delivered(uint256 indexed dealId)",
]);

// CaseStatus enum: 0 None, 1 Pending, 2 Ruled, 3 Final, 4 Errored.
const CASE_RULED = 2;
const CASE_FINAL = 3;
const CASE_ERRORED = 4;

// DealStatus enum: 0 None, 1 Funded, 2 Delivered, 3 Disputed, 4 Settled.
const DEAL_DELIVERED = 2;

function die(msg) {
  console.error(`error: ${msg}`);
  process.exit(2);
}

function parseOptionalBlock(value, name) {
  if (!value) return null;
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
  const {
    PRIVATE_KEY,
    SHANNON_RPC,
    COURT_ADDRESS,
    ESCROW_ADDRESS,
    START_BLOCK,
    POLL_INTERVAL_MS,
  } = process.env;
  if (!PRIVATE_KEY || !/^0x[0-9a-fA-F]{64}$/.test(PRIVATE_KEY)) {
    die("PRIVATE_KEY missing or not a 0x-prefixed 32-byte hex string");
  }
  if (!COURT_ADDRESS || !/^0x[0-9a-fA-F]{40}$/.test(COURT_ADDRESS)) {
    die("COURT_ADDRESS missing or invalid");
  }
  if (!ESCROW_ADDRESS || !/^0x[0-9a-fA-F]{40}$/.test(ESCROW_ADDRESS)) {
    die("ESCROW_ADDRESS missing or invalid");
  }
  const startBlock = parseOptionalBlock(START_BLOCK, "START_BLOCK");
  const pollMs = POLL_INTERVAL_MS ? Number(POLL_INTERVAL_MS) : DEFAULT_POLL_MS;
  if (!Number.isInteger(pollMs) || pollMs < 1000) {
    die(`POLL_INTERVAL_MS must be an integer >= 1000; got ${POLL_INTERVAL_MS}`);
  }
  return {
    privateKey: PRIVATE_KEY,
    rpc: parseRpc(SHANNON_RPC),
    court: COURT_ADDRESS,
    escrow: ESCROW_ADDRESS,
    startBlock,
    pollMs,
  };
}

const VERDICT_EVENT = COURT_ABI.find(
  (f) => f.type === "event" && f.name === "VerdictReached",
);
const DELIVERED_EVENT = ESCROW_ABI.find(
  (f) => f.type === "event" && f.name === "Delivered",
);

// Scan [fromBlock, toBlock] in <= MAX_LOG_RANGE chunks (Somnia rejects wider getLogs ranges).
async function scanLogs(publicClient, address, event, fromBlock, toBlock) {
  const out = [];
  let start = fromBlock;
  while (start <= toBlock) {
    const end =
      start + MAX_LOG_RANGE - 1n < toBlock
        ? start + MAX_LOG_RANGE - 1n
        : toBlock;
    const logs = await publicClient.getLogs({
      address,
      event,
      fromBlock: start,
      toBlock: end,
    });
    out.push(...logs);
    start = end + 1n;
  }
  return out;
}

async function tryFinalize(ctx, caseId) {
  const c = await ctx.publicClient.readContract({
    address: ctx.court,
    abi: COURT_ABI,
    functionName: "getCase",
    args: [caseId],
  });
  const status = Number(c.status);
  if (status === CASE_FINAL || status === CASE_ERRORED) {
    ctx.settledCases.add(caseId);
    return;
  }
  if (status !== CASE_RULED) return;

  const now = ctx.latestTimestamp;
  const windowEnd = c.rulingTime + ctx.appealWindow;
  // MAX_ROUND rulings can finalize immediately; otherwise wait out the appeal window.
  if (c.round < ctx.maxRound && now <= windowEnd) return;

  const hash = await ctx.walletClient.writeContract({
    address: ctx.court,
    abi: COURT_ABI,
    functionName: "finalize",
    args: [caseId],
    chain: null,
  });
  console.log(`[finalize] caseId=${caseId} tx=${hash}`);
  ctx.settledCases.add(caseId);
}

async function tryRelease(ctx, dealId) {
  const d = await ctx.publicClient.readContract({
    address: ctx.escrow,
    abi: ESCROW_ABI,
    functionName: "deals",
    args: [dealId],
  });
  // viem decodes a tuple-returning view as a positional array.
  const [, , , statusRaw, deliverBy] = d;
  const status = Number(statusRaw);
  if (status !== DEAL_DELIVERED) {
    if (status > DEAL_DELIVERED) ctx.releasedDeals.add(dealId);
    return;
  }
  const now = ctx.latestTimestamp;
  if (now <= deliverBy) return;

  const hash = await ctx.walletClient.writeContract({
    address: ctx.escrow,
    abi: ESCROW_ABI,
    functionName: "release",
    args: [dealId],
    chain: null,
  });
  console.log(`[release] dealId=${dealId} tx=${hash}`);
  ctx.releasedDeals.add(dealId);
}

async function tick(ctx) {
  // Incrementally scan blocks since the cursor and accumulate ids into persistent watch
  // sets, so a case seen once stays watched until settled even after its event scrolls past
  // the getLogs window (Somnia runs ~20 blocks/s; a fixed lookback would lose it).
  try {
    const latest = await ctx.publicClient.getBlockNumber();
    if (ctx.cursor <= latest) {
      const block = await ctx.publicClient.getBlock({ blockNumber: latest });
      ctx.latestTimestamp = block.timestamp;
      const caseLogs = await scanLogs(
        ctx.publicClient,
        ctx.court,
        VERDICT_EVENT,
        ctx.cursor,
        latest,
      );
      for (const l of caseLogs) ctx.watchedCases.add(l.args.caseId);
      const dealLogs = await scanLogs(
        ctx.publicClient,
        ctx.escrow,
        DELIVERED_EVENT,
        ctx.cursor,
        latest,
      );
      for (const l of dealLogs) ctx.watchedDeals.add(l.args.dealId);
      ctx.cursor = latest + 1n;
    }
  } catch (err) {
    console.error(`[scan] error: ${err.shortMessage ?? err.message}`);
  }

  let actions = 0;
  for (const id of ctx.watchedCases) {
    if (ctx.settledCases.has(id)) continue;
    try {
      const before = ctx.settledCases.size;
      await tryFinalize(ctx, id);
      if (ctx.settledCases.size > before) actions += 1;
    } catch (err) {
      console.error(
        `[finalize] caseId=${id} error: ${err.shortMessage ?? err.message}`,
      );
    }
  }
  for (const id of ctx.watchedDeals) {
    if (ctx.releasedDeals.has(id)) continue;
    try {
      const before = ctx.releasedDeals.size;
      await tryRelease(ctx, id);
      if (ctx.releasedDeals.size > before) actions += 1;
    } catch (err) {
      console.error(
        `[release] dealId=${id} error: ${err.shortMessage ?? err.message}`,
      );
    }
  }

  if (actions === 0) console.log("[idle] no actionable items");
}

async function main() {
  const cfg = readEnv();
  const account = privateKeyToAccount(cfg.privateKey);
  const transport = http(cfg.rpc);
  const publicClient = createPublicClient({ transport });
  const walletClient = createWalletClient({ account, transport });

  const [appealWindow, maxRound] = await Promise.all([
    publicClient.readContract({
      address: cfg.court,
      abi: COURT_ABI,
      functionName: "appealWindow",
    }),
    publicClient.readContract({
      address: cfg.court,
      abi: COURT_ABI,
      functionName: "MAX_ROUND",
    }),
  ]);
  const latest = await publicClient.getBlockNumber();
  const initialCursor =
    cfg.startBlock ??
    (latest > MAX_LOG_RANGE ? latest - MAX_LOG_RANGE + 1n : 0n);

  console.log(`verdikt-keeper`);
  console.log(`  rpc          : ${cfg.rpc}`);
  console.log(`  sender       : ${account.address}`);
  console.log(`  court        : ${cfg.court}`);
  console.log(`  escrow       : ${cfg.escrow}`);
  console.log(
    `  startBlock   : ${cfg.startBlock ?? `(recent, from ${initialCursor})`}`,
  );
  console.log(`  pollInterval : ${cfg.pollMs}ms`);
  console.log(`  appealWindow : ${appealWindow}s`);
  console.log(`  maxRound     : ${maxRound}`);

  const ctx = {
    publicClient,
    walletClient,
    court: cfg.court,
    escrow: cfg.escrow,
    startBlock: initialCursor,
    cursor: initialCursor,
    latestTimestamp: 0n,
    appealWindow,
    maxRound: Number(maxRound),
    watchedCases: new Set(),
    watchedDeals: new Set(),
    settledCases: new Set(),
    releasedDeals: new Set(),
  };

  let stopped = false;
  process.on("SIGINT", () => {
    if (stopped) return;
    stopped = true;
    console.log("\n[shutdown] SIGINT received; exiting.");
    process.exit(0);
  });

  // Run immediately, then on a fixed interval.
  while (!stopped) {
    await tick(ctx);
    if (stopped) break;
    await new Promise((r) => setTimeout(r, cfg.pollMs));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
