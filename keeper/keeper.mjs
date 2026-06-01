// SPDX-License-Identifier: MIT
//
// Verdikt keeper — drives the two permissionless settlement paths on Shannon:
//
//   1. VerdiktCourt.finalize(caseId)   once a ruling's appeal window has elapsed
//   2. VerdiktEscrow.release(dealId)   once a delivered deal is past deliverBy
//
// Discovery is by enumerating authoritative contract state (Court.nextCaseId /
// Escrow.nextDealId, then getCase / deals) rather than scanning event logs. Somnia's
// eth_getLogs intermittently returns an empty success under load, and a moving log cursor
// that advances past a dropped event would miss that case forever; reading the contract's
// own counters via eth_call is immune to that (and is covered by the fallback transport's
// retry/failover). Already-settled ids are cached so each tick stays cheap.

import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import {
  createPublicClient,
  createWalletClient,
  fallback,
  http,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "..", ".env") });

// Known-good Shannon endpoints. The keeper always runs over ALL of these via a viem
// fallback transport (configured RPC first), so an intermittent timeout/error on one
// endpoint transparently retries on the next instead of stalling settlement.
const DEFAULT_RPCS = [
  "https://api.infra.testnet.somnia.network/",
  "https://dream-rpc.somnia.network/",
];
const HTTP_TIMEOUT_MS = 15_000;
const HTTP_RETRY_COUNT = 3;
const DEFAULT_POLL_MS = 30_000;

const COURT_ABI = parseAbi([
  "function finalize(uint256 caseId)",
  "function appealWindow() view returns (uint64)",
  "function nextCaseId() view returns (uint256)",
  "function getCase(uint256 caseId) view returns (address consumer, uint256 escrowRef, uint8 round, uint8 status, uint8 verdict, uint256 receiptId, uint64 rulingTime)",
  "function MAX_ROUND() view returns (uint8)",
]);

const ESCROW_ABI = parseAbi([
  "function release(uint256 dealId)",
  "function nextDealId() view returns (uint256)",
  "function deals(uint256) view returns (address payer, address payee, uint256 amount, uint8 status, uint64 deliverBy, uint256 caseId)",
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

// Accept an optional comma-separated SHANNON_RPC, then always append the known-good
// endpoints as automatic fallbacks (deduped, configured-first).
function parseRpcs(value) {
  const configured = value
    ? value
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
    : [];
  const rpcs = [...new Set([...configured, ...DEFAULT_RPCS])];
  for (const rpc of rpcs) {
    try {
      const url = new URL(rpc);
      if (url.protocol !== "https:" && url.protocol !== "http:") {
        die(`SHANNON_RPC entries must be http(s); got ${url.protocol}`);
      }
    } catch {
      die(`SHANNON_RPC is not a valid URL: ${rpc}`);
    }
  }
  return rpcs;
}

function readEnv() {
  const { PRIVATE_KEY, SHANNON_RPC, COURT_ADDRESS, ESCROW_ADDRESS, POLL_INTERVAL_MS } =
    process.env;
  if (!PRIVATE_KEY || !/^0x[0-9a-fA-F]{64}$/.test(PRIVATE_KEY)) {
    die("PRIVATE_KEY missing or not a 0x-prefixed 32-byte hex string");
  }
  if (!COURT_ADDRESS || !/^0x[0-9a-fA-F]{40}$/.test(COURT_ADDRESS)) {
    die("COURT_ADDRESS missing or invalid");
  }
  if (!ESCROW_ADDRESS || !/^0x[0-9a-fA-F]{40}$/.test(ESCROW_ADDRESS)) {
    die("ESCROW_ADDRESS missing or invalid");
  }
  const pollMs = POLL_INTERVAL_MS ? Number(POLL_INTERVAL_MS) : DEFAULT_POLL_MS;
  if (!Number.isInteger(pollMs) || pollMs < 1000) {
    die(`POLL_INTERVAL_MS must be an integer >= 1000; got ${POLL_INTERVAL_MS}`);
  }
  return {
    privateKey: PRIVATE_KEY,
    rpcs: parseRpcs(SHANNON_RPC),
    court: COURT_ADDRESS,
    escrow: ESCROW_ADDRESS,
    pollMs,
  };
}

async function tryFinalize(ctx, caseId) {
  const c = await ctx.publicClient.readContract({
    address: ctx.court,
    abi: COURT_ABI,
    functionName: "getCase",
    args: [caseId],
  });
  // viem decodes a multi-value view as a positional array, so read by index
  // (consumer, escrowRef, round, status, verdict, receiptId, rulingTime).
  const [, , round, statusRaw, , , rulingTime] = c;
  const status = Number(statusRaw);
  if (status === CASE_FINAL || status === CASE_ERRORED) {
    ctx.settledCases.add(caseId);
    return;
  }
  if (status !== CASE_RULED) return;

  const now = ctx.latestTimestamp;
  const windowEnd = rulingTime + ctx.appealWindow;
  // MAX_ROUND rulings can finalize immediately; otherwise wait out the appeal window.
  if (round < ctx.maxRound && now <= windowEnd) return;

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
  // Read the current block time and the contract counters; everything below works off
  // authoritative state, so a flaky getLogs can never make us miss a case.
  let nextCaseId = 1n;
  let nextDealId = 1n;
  try {
    const latest = await ctx.publicClient.getBlockNumber();
    const block = await ctx.publicClient.getBlock({ blockNumber: latest });
    ctx.latestTimestamp = block.timestamp;
    [nextCaseId, nextDealId] = await Promise.all([
      ctx.publicClient.readContract({
        address: ctx.court,
        abi: COURT_ABI,
        functionName: "nextCaseId",
      }),
      ctx.publicClient.readContract({
        address: ctx.escrow,
        abi: ESCROW_ABI,
        functionName: "nextDealId",
      }),
    ]);
  } catch (err) {
    console.error(`[scan] error: ${err.shortMessage ?? err.message}`);
    return;
  }

  let actions = 0;
  for (let id = 1n; id < nextCaseId; id++) {
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
  for (let id = 1n; id < nextDealId; id++) {
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
  const transport = fallback(
    cfg.rpcs.map((url) =>
      http(url, { timeout: HTTP_TIMEOUT_MS, retryCount: HTTP_RETRY_COUNT }),
    ),
  );
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

  console.log(`verdikt-keeper`);
  console.log(`  rpcs         : ${cfg.rpcs.join(", ")} (auto-failover)`);
  console.log(`  sender       : ${account.address}`);
  console.log(`  court        : ${cfg.court}`);
  console.log(`  escrow       : ${cfg.escrow}`);
  console.log(`  pollInterval : ${cfg.pollMs}ms`);
  console.log(`  appealWindow : ${appealWindow}s`);
  console.log(`  maxRound     : ${maxRound}`);

  const ctx = {
    publicClient,
    walletClient,
    court: cfg.court,
    escrow: cfg.escrow,
    latestTimestamp: 0n,
    appealWindow,
    maxRound: Number(maxRound),
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
