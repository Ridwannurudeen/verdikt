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
import {
    createPublicClient,
    createWalletClient,
    http,
    parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "..", ".env") });

const DEFAULT_RPC = "https://api.infra.testnet.somnia.network/";
const DEFAULT_POLL_MS = 30_000;

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
    const startBlock = START_BLOCK ? BigInt(START_BLOCK) : 0n;
    const pollMs = POLL_INTERVAL_MS ? Number(POLL_INTERVAL_MS) : DEFAULT_POLL_MS;
    if (!Number.isInteger(pollMs) || pollMs < 1000) {
        die(`POLL_INTERVAL_MS must be an integer >= 1000; got ${POLL_INTERVAL_MS}`);
    }
    return {
        privateKey: PRIVATE_KEY,
        rpc: SHANNON_RPC || DEFAULT_RPC,
        court: COURT_ADDRESS,
        escrow: ESCROW_ADDRESS,
        startBlock,
        pollMs,
    };
}

async function discoverCases(publicClient, court, fromBlock) {
    const logs = await publicClient.getLogs({
        address: court,
        event: COURT_ABI.find((f) => f.type === "event" && f.name === "VerdictReached"),
        fromBlock,
        toBlock: "latest",
    });
    const ids = new Set();
    for (const log of logs) ids.add(log.args.caseId);
    return ids;
}

async function discoverDeals(publicClient, escrow, fromBlock) {
    const logs = await publicClient.getLogs({
        address: escrow,
        event: ESCROW_ABI.find((f) => f.type === "event" && f.name === "Delivered"),
        fromBlock,
        toBlock: "latest",
    });
    const ids = new Set();
    for (const log of logs) ids.add(log.args.dealId);
    return ids;
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

    const now = BigInt(Math.floor(Date.now() / 1000));
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
    const now = BigInt(Math.floor(Date.now() / 1000));
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
    let actions = 0;
    try {
        const caseIds = await discoverCases(ctx.publicClient, ctx.court, ctx.startBlock);
        for (const id of caseIds) {
            if (ctx.settledCases.has(id)) continue;
            try {
                const before = ctx.settledCases.size;
                await tryFinalize(ctx, id);
                if (ctx.settledCases.size > before) actions += 1;
            } catch (err) {
                console.error(`[finalize] caseId=${id} error: ${err.shortMessage ?? err.message}`);
            }
        }
    } catch (err) {
        console.error(`[discover cases] error: ${err.shortMessage ?? err.message}`);
    }

    try {
        const dealIds = await discoverDeals(ctx.publicClient, ctx.escrow, ctx.startBlock);
        for (const id of dealIds) {
            if (ctx.releasedDeals.has(id)) continue;
            try {
                const before = ctx.releasedDeals.size;
                await tryRelease(ctx, id);
                if (ctx.releasedDeals.size > before) actions += 1;
            } catch (err) {
                console.error(`[release] dealId=${id} error: ${err.shortMessage ?? err.message}`);
            }
        }
    } catch (err) {
        console.error(`[discover deals] error: ${err.shortMessage ?? err.message}`);
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
        publicClient.readContract({ address: cfg.court, abi: COURT_ABI, functionName: "appealWindow" }),
        publicClient.readContract({ address: cfg.court, abi: COURT_ABI, functionName: "MAX_ROUND" }),
    ]);

    console.log(`verdikt-keeper`);
    console.log(`  rpc          : ${cfg.rpc}`);
    console.log(`  sender       : ${account.address}`);
    console.log(`  court        : ${cfg.court}`);
    console.log(`  escrow       : ${cfg.escrow}`);
    console.log(`  startBlock   : ${cfg.startBlock}`);
    console.log(`  pollInterval : ${cfg.pollMs}ms`);
    console.log(`  appealWindow : ${appealWindow}s`);
    console.log(`  maxRound     : ${maxRound}`);

    const ctx = {
        publicClient,
        walletClient,
        court: cfg.court,
        escrow: cfg.escrow,
        startBlock: cfg.startBlock,
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
