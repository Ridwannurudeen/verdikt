// SPDX-License-Identifier: MIT
//
// One-shot driver for the Verdikt determinism probe on Somnia Shannon.
//
//   node run-determinism-gate.mjs <PROBE_ADDR> [evidence] [panel]
//
// Reads PRIVATE_KEY, SHANNON_RPC, LLM_AGENT_ID from ../.env.
// Computes the exact panel fee on-chain (no guessing), fires fire(evidence, panel),
// polls getResults() every 10s for up to 5 minutes, and prints a verdict-frequency
// histogram so the operator can see convergence at a glance.
//
// Exit codes: 0 = results landed, 1 = timeout / no results, 2 = config error.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import {
    createPublicClient,
    createWalletClient,
    decodeEventLog,
    http,
    parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const __dirname = dirname(fileURLToPath(import.meta.url));
loadEnv({ path: resolve(__dirname, "..", ".env") });

const POLL_INTERVAL_MS = 10_000;
const POLL_TIMEOUT_MS = 5 * 60_000;
const DEFAULT_PANEL = 5;
const DEFAULT_EVIDENCE =
    "buyer claims item never arrived; seller shows tracking delivered to buyer's address";

const PROBE_ABI = parseAbi([
    "function fire(string evidence, uint256 panel) payable returns (uint256)",
    "function getResults() view returns (string[])",
    "function lastStatus() view returns (uint8)",
    "function lastRequestId() view returns (uint256)",
    "function platform() view returns (address)",
    "event Probed(uint256 requestId, uint256 panel)",
    "event ProbeResult(uint256 requestId, uint8 status, uint256 resultCount)",
]);

const PLATFORM_ABI = parseAbi([
    "function getAdvancedRequestDeposit(uint256 subcommitteeSize) view returns (uint256)",
]);

// Mirrors VerdiktCourt.perAgentPrice (docs: 0.07 STT per LLM-inference agent).
const PER_AGENT_PRICE_WEI = 70_000_000_000_000_000n; // 0.07 ether

const STATUS_LABELS = ["None", "Pending", "Success", "Failed", "TimedOut"];

function die(code, msg) {
    console.error(`error: ${msg}`);
    process.exit(code);
}

function parseArgs() {
    const [probeArg, evidenceArg, panelArg] = process.argv.slice(2);
    if (!probeArg) {
        die(
            2,
            "usage: node run-determinism-gate.mjs <PROBE_ADDR> [evidence] [panel]",
        );
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(probeArg)) {
        die(2, `<PROBE_ADDR> is not a valid 0x address: ${probeArg}`);
    }
    const panel = panelArg ? Number(panelArg) : DEFAULT_PANEL;
    if (!Number.isInteger(panel) || panel < 1 || panel > 50) {
        die(2, `panel must be an integer in [1, 50]; got ${panelArg}`);
    }
    return {
        probe: probeArg,
        evidence: evidenceArg ?? DEFAULT_EVIDENCE,
        panel: BigInt(panel),
    };
}

function readEnv() {
    const { PRIVATE_KEY, SHANNON_RPC, LLM_AGENT_ID } = process.env;
    if (!PRIVATE_KEY || !/^0x[0-9a-fA-F]{64}$/.test(PRIVATE_KEY)) {
        die(2, "PRIVATE_KEY missing or not a 0x-prefixed 32-byte hex string");
    }
    if (!SHANNON_RPC) die(2, "SHANNON_RPC missing");
    if (!LLM_AGENT_ID) die(2, "LLM_AGENT_ID missing");
    return { PRIVATE_KEY, SHANNON_RPC, LLM_AGENT_ID };
}

function formatStt(wei) {
    // 18 decimals; show 4 decimal places.
    const whole = wei / 10n ** 18n;
    const frac = (wei % 10n ** 18n) / 10n ** 14n; // 4 decimals
    return `${whole}.${frac.toString().padStart(4, "0")} STT`;
}

function histogram(results) {
    const counts = new Map();
    for (const r of results) counts.set(r, (counts.get(r) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

function renderHistogram(rows, total) {
    if (rows.length === 0) return "  (no results)";
    const widest = rows[0][1];
    return rows
        .map(([label, n]) => {
            const bar = "#".repeat(Math.round((n / widest) * 24));
            const pct = ((n / total) * 100).toFixed(0).padStart(3);
            return `  ${label.padEnd(8)} ${String(n).padStart(2)}/${total}  ${pct}%  ${bar}`;
        })
        .join("\n");
}

async function main() {
    const args = parseArgs();
    const env = readEnv();

    const account = privateKeyToAccount(env.PRIVATE_KEY);
    const transport = http(env.SHANNON_RPC);
    const publicClient = createPublicClient({ transport });
    const walletClient = createWalletClient({ account, transport });

    console.log(`probe       : ${args.probe}`);
    console.log(`sender      : ${account.address}`);
    console.log(`panel size  : ${args.panel}`);
    console.log(`evidence    : ${args.evidence}`);

    const platform = await publicClient.readContract({
        address: args.probe,
        abi: PROBE_ABI,
        functionName: "platform",
    });
    console.log(`platform    : ${platform}`);

    const deposit = await publicClient.readContract({
        address: platform,
        abi: PLATFORM_ABI,
        functionName: "getAdvancedRequestDeposit",
        args: [args.panel],
    });
    const fee = deposit + PER_AGENT_PRICE_WEI * args.panel;
    console.log(
        `fee         : ${formatStt(fee)}  (deposit ${formatStt(deposit)} + ${args.panel} * 0.0700 STT)`,
    );

    console.log("\nfiring probe...");
    const txHash = await walletClient.writeContract({
        address: args.probe,
        abi: PROBE_ABI,
        functionName: "fire",
        args: [args.evidence, args.panel],
        value: fee,
        chain: null,
    });
    console.log(`tx          : ${txHash}`);

    const receipt = await publicClient.waitForTransactionReceipt({
        hash: txHash,
    });
    if (receipt.status !== "success") {
        die(1, `fire() transaction reverted (status=${receipt.status})`);
    }

    let requestId;
    for (const log of receipt.logs) {
        try {
            const ev = decodeEventLog({
                abi: PROBE_ABI,
                data: log.data,
                topics: log.topics,
            });
            if (ev.eventName === "Probed") {
                requestId = ev.args.requestId;
                break;
            }
        } catch {
            // not one of our events
        }
    }
    if (requestId === undefined) {
        console.log(
            "warning: did not find Probed event in receipt; polling anyway",
        );
    } else {
        console.log(`requestId   : ${requestId}`);
    }

    console.log(
        `\npolling getResults() every ${POLL_INTERVAL_MS / 1000}s (timeout ${POLL_TIMEOUT_MS / 1000}s)...`,
    );
    const deadline = Date.now() + POLL_TIMEOUT_MS;
    let results = [];
    let status = 0;
    while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
        const [r, s] = await Promise.all([
            publicClient.readContract({
                address: args.probe,
                abi: PROBE_ABI,
                functionName: "getResults",
            }),
            publicClient.readContract({
                address: args.probe,
                abi: PROBE_ABI,
                functionName: "lastStatus",
            }),
        ]);
        results = r;
        status = Number(s);
        const elapsed = Math.round((POLL_TIMEOUT_MS - (deadline - Date.now())) / 1000);
        console.log(
            `  [+${String(elapsed).padStart(3)}s] status=${STATUS_LABELS[status] ?? status} results=${results.length}`,
        );
        if (results.length > 0) break;
    }

    if (results.length === 0) {
        console.log("\nFAIL: no results landed within timeout.");
        console.log(
            "  Check the request on the explorer / Somnia agents dashboard; the panel may still be pending.",
        );
        process.exit(1);
    }

    const total = results.length;
    const rows = histogram(results);
    const [topLabel, topCount] = rows[0];
    const converged = topCount === total;
    const majority = topCount * 2 > total;

    console.log("\nverdict histogram");
    console.log("-----------------");
    console.log(renderHistogram(rows, total));
    console.log(
        `\nfinal status: ${STATUS_LABELS[status] ?? status}   responses: ${total}   top: ${topLabel} (${topCount}/${total})`,
    );

    if (converged) {
        console.log("\nPASS: panel converged byte-identically.");
    } else if (majority) {
        console.log(
            "\nPARTIAL: majority converged but panel was not unanimous; review divergent outputs.",
        );
    } else {
        console.log(
            "\nFAIL: no majority. Consider PAYEE/PAYER-only allowedValues and/or chainOfThought=false.",
        );
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
