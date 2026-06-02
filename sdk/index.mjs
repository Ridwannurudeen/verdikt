// Verdikt JS SDK — a thin viem client for reading cases, watching verdicts, and encoding disputes.
// Pairs with the Foundry library (VerdiktConsumerBase + interfaces) for the on-chain side.
//
//   import { createVerdiktClient, VERDICT } from "./sdk/index.mjs";
//   const verdikt = createVerdiktClient({ publicClient, court: "0x..." });
//   const c = await verdikt.getCase(1);                 // { verdictLabel, statusLabel, ... }
//   verdikt.watchVerdicts((v) => console.log(v.caseId, v.verdict));

import { parseAbi } from "viem";

export const COURT_ABI = parseAbi([
  "function openCase(uint256 escrowRef, string evidence) payable returns (uint256)",
  "function appeal(uint256 caseId, string newEvidence) payable",
  "function finalize(uint256 caseId)",
  "function quoteOpen() view returns (uint256)",
  "function quoteAppeal(uint256 caseId) view returns (uint256)",
  "function getCase(uint256 caseId) view returns ((address consumer,uint256 escrowRef,uint8 round,uint8 status,uint8 verdict,uint256 receiptId,uint64 rulingTime))",
  "function splitBps(uint256 caseId) view returns (uint16)",
  "function appealDeadlineOf(uint256 caseId) view returns (uint64)",
  "function promptVersionOf(uint256 caseId) view returns (uint256)",
  "event CaseOpened(uint256 indexed caseId, address indexed consumer, uint256 indexed escrowRef)",
  "event VerdictReached(uint256 indexed caseId, uint8 verdict, uint8 round, uint256 receiptId)",
  "event CaseFinalized(uint256 indexed caseId, uint8 verdict)",
]);

export const VERDICT = { 0: "NONE", 1: "PAYEE", 2: "PAYER", 3: "SPLIT", 4: "UNDECIDABLE" };
export const CASE_STATUS = { 0: "None", 1: "Pending", 2: "Ruled", 3: "Final", 4: "Errored" };

/// Resolve any verdict to the payee's share (basis points), graded-SPLIT aware.
export async function payeeShareBps(client, caseId) {
  const c = await client.getCase(caseId);
  if (c.verdictLabel === "PAYEE") return 10000;
  if (c.verdictLabel === "SPLIT") return Number(await client.splitBps(caseId));
  return 0; // PAYER / UNDECIDABLE / NONE
}

export function createVerdiktClient({ publicClient, court }) {
  const read = (functionName, args = []) => publicClient.readContract({ address: court, abi: COURT_ABI, functionName, args });
  const client = {
    court,
    quoteOpen: () => read("quoteOpen"),
    quoteAppeal: (caseId) => read("quoteAppeal", [BigInt(caseId)]),
    splitBps: (caseId) => read("splitBps", [BigInt(caseId)]),
    appealDeadlineOf: (caseId) => read("appealDeadlineOf", [BigInt(caseId)]),
    promptVersionOf: (caseId) => read("promptVersionOf", [BigInt(caseId)]),
    async getCase(caseId) {
      const c = await read("getCase", [BigInt(caseId)]);
      return { ...c, verdictLabel: VERDICT[c.verdict] ?? "?", statusLabel: CASE_STATUS[c.status] ?? "?" };
    },
    /// Subscribe to verdicts. Returns the viem unwatch function.
    watchVerdicts(onVerdict) {
      return publicClient.watchContractEvent({
        address: court,
        abi: COURT_ABI,
        eventName: "VerdictReached",
        onLogs: (logs) =>
          logs.forEach((l) =>
            onVerdict({
              caseId: l.args.caseId,
              verdict: VERDICT[l.args.verdict] ?? "?",
              round: Number(l.args.round),
              receiptId: l.args.receiptId,
            })
          ),
      });
    },
  };
  return client;
}
