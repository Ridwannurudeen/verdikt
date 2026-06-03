// Verdikt autonomous-agent SDK — lets an agent (with a wallet) act in the court: read cases, file
// appeals, run as a decentralized keeper (finalize ready cases), and earn keeper bounties. Pairs with
// index.mjs (read-only client) and VerdiktConsumerBase (the on-chain consumer side).
//
//   import { createVerdiktAgent } from "./sdk/agent.mjs";
//   const agent = createVerdiktAgent({ publicClient, walletClient, account, court: "0x..." });
//   await agent.runKeeper();                 // finalize every case whose window has passed
//   await agent.appeal(caseId, "new evidence");

import { parseAbi } from "viem";
import { VERDICT, CASE_STATUS } from "./index.mjs";

const AGENT_ABI = parseAbi([
  "function appeal(uint256 caseId, string newEvidence) payable",
  "function finalize(uint256 caseId)",
  "function retry(uint256 caseId) payable",
  "function quoteAppeal(uint256 caseId) view returns (uint256)",
  "function nextCaseId() view returns (uint256)",
  "function appealDeadlineOf(uint256 caseId) view returns (uint64)",
  "function MAX_ROUND() view returns (uint8)",
  "function getCase(uint256 caseId) view returns ((address consumer,uint256 escrowRef,uint8 round,uint8 status,uint8 verdict,uint256 receiptId,uint64 rulingTime))",
]);

const BOUNTY_ABI = parseAbi([
  "function finalizeAndClaim(address court, uint256 caseId)",
  "function pot(bytes32 key) view returns (uint256)",
  "function key(address court, uint256 caseId) view returns (bytes32)",
]);

const RULED = 2;

export function createVerdiktAgent({
  publicClient,
  walletClient,
  account,
  court,
}) {
  const read = (functionName, args = []) =>
    publicClient.readContract({
      address: court,
      abi: AGENT_ABI,
      functionName,
      args,
    });
  const write = (functionName, args, value = 0n) =>
    walletClient.writeContract({
      address: court,
      abi: AGENT_ABI,
      functionName,
      args,
      value,
      account,
      chain: null,
    });

  const agent = {
    court,

    async getCase(caseId) {
      const c = await read("getCase", [BigInt(caseId)]);
      return {
        ...c,
        verdictLabel: VERDICT[c.verdict] ?? "?",
        statusLabel: CASE_STATUS[c.status] ?? "?",
      };
    },

    /// File an appeal with new evidence (auto-quotes the larger-panel fee).
    async appeal(caseId, newEvidence) {
      const fee = await read("quoteAppeal", [BigInt(caseId)]);
      return write("appeal", [BigInt(caseId), newEvidence], fee);
    },

    /// Settle a single ruled case whose appeal window has passed.
    finalize(caseId) {
      return write("finalize", [BigInt(caseId)]);
    },

    /// Decentralized keeper sweep: finalize every case that is Ruled and past its snapshotted appeal deadline
    /// (or at MAX_ROUND). Returns the cases it settled. `now` overridable for testing.
    async runKeeper({
      now = BigInt(Math.floor(Date.now() / 1000)),
      onAction,
    } = {}) {
      const [next, maxRound] = await Promise.all([
        read("nextCaseId"),
        read("MAX_ROUND"),
      ]);
      const settled = [];
      for (let id = 1n; id < next; id++) {
        let c;
        try {
          c = await read("getCase", [id]);
        } catch {
          continue;
        }
        if (Number(c.status) !== RULED) continue;
        const windowEnd = await read("appealDeadlineOf", [id]);
        if (Number(c.round) < Number(maxRound) && now <= windowEnd) continue;
        try {
          const tx = await write("finalize", [id]);
          settled.push({ caseId: id, tx });
          onAction?.({ caseId: id, tx });
        } catch {
          // already finalized or not ready — skip
        }
      }
      return settled;
    },

    /// Finalize a case via the keeper-bounty contract and take the pot (settle + earn in one tx).
    async finalizeForBounty(bounty, caseId) {
      return walletClient.writeContract({
        address: bounty,
        abi: BOUNTY_ABI,
        functionName: "finalizeAndClaim",
        args: [court, BigInt(caseId)],
        account,
        chain: null,
      });
    },

    /// Current bounty (wei) on offer for finalizing a case.
    async bountyFor(bounty, caseId) {
      const k = await publicClient.readContract({
        address: bounty,
        abi: BOUNTY_ABI,
        functionName: "key",
        args: [court, BigInt(caseId)],
      });
      return publicClient.readContract({
        address: bounty,
        abi: BOUNTY_ABI,
        functionName: "pot",
        args: [k],
      });
    },
  };
  return agent;
}
