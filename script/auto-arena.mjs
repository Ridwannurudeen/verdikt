// Verdikt — Autonomous Agent Arena driver.
//
// Two autonomous agents transact, dispute, and settle through Verdikt's AI court with NO human in the
// loop: a BuyerAgent opens an escrow deal with a SellerAgent; the seller fails to deliver; the buyer
// agent autonomously files a dispute with machine-generated evidence; a panel of Somnia validator LLM
// agents rules; the escrow settles itself; the verdict is recorded as on-chain precedent. Repeat.
//
// Run (PowerShell): from repo root, with a funded BUYER_PK in scope:
//   node script/auto-arena.mjs
// Env: BUYER_PK (required, 0x-hex), ROUNDS (default 1), SELLER (payee addr), RPC/ESCROW/COURT/REGISTRY
// (default to the live premium stack below).

import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  parseEther,
  formatEther,
  keccak256,
  stringToHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = process.env.RPC || "https://api.infra.testnet.somnia.network/";
const ESCROW =
  process.env.ESCROW || "0x91AaCFDF78D32Fa213408e7e5a187Af697fB099d";
const COURT = process.env.COURT || "0xeBbA8b849343150e994BEE34778D4D8D38941eDE";
const REGISTRY =
  process.env.REGISTRY || "0xd1e91c0167a3F5a5aC0F61f86E3883921610261E";
const SELLER =
  process.env.SELLER || "0x000000000000000000000000000000000000dEaD";
const ROUNDS = Number(process.env.ROUNDS || 1);
const TOPIC = keccak256(stringToHex("verdikt/escrow/dispute"));

const shannon = {
  id: 50312,
  name: "Somnia Shannon Testnet",
  nativeCurrency: { name: "STT", symbol: "STT", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
};

const ESCROW_ABI = parseAbi([
  "function createDeal(address payee, uint64 deliverBy) payable returns (uint256)",
  "function dispute(uint256 dealId, string evidence, uint8 trialPanel) payable",
  "function deals(uint256) view returns (address payer, address payee, uint256 amount, uint8 status, uint64 deliverBy, uint256 caseId)",
  "function pending(address) view returns (uint256)",
  "function nextDealId() view returns (uint256)",
  "function withdraw() returns (uint256)",
]);
const COURT_ABI = parseAbi([
  "function quoteOpen(uint8 trialPanel) view returns (uint256)",
  "function getCase(uint256) view returns ((address consumer,uint256 escrowRef,uint8 round,uint8 status,uint8 verdict,uint256 receiptId,uint64 rulingTime))",
  "function finalize(uint256 caseId)",
  "function appealDeadlineOf(uint256 caseId) view returns (uint64)",
  "function modelOf(uint256 caseId) view returns (uint256)",
]);
const REGISTRY_ABI = parseAbi([
  "function record(uint256 caseId, bytes32 topic)",
]);

const VERDICT = [
  "NONE",
  "PAYEE (seller)",
  "PAYER (refund buyer)",
  "SPLIT",
  "UNDECIDABLE (abstained → safe refund)",
];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (m) => console.log(m);

if (!process.env.BUYER_PK) {
  console.error(
    "Set BUYER_PK (a funded Shannon key, 0x-hex) — the autonomous BuyerAgent's wallet.",
  );
  process.exit(1);
}
const buyer = privateKeyToAccount(process.env.BUYER_PK);
const pub = createPublicClient({ chain: shannon, transport: http(RPC) });
const wallet = createWalletClient({
  account: buyer,
  chain: shannon,
  transport: http(RPC),
});

const read = (address, abi, functionName, args = []) =>
  pub.readContract({ address, abi, functionName, args });
async function send(address, abi, functionName, args = [], value = 0n) {
  const hash = await wallet.writeContract({
    address,
    abi,
    functionName,
    args,
    value,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success")
    throw new Error(`${functionName} reverted (${hash})`);
  return receipt;
}

async function pickPanel(dealId, evidence) {
  for (let p = 5; p >= 3; p--) {
    try {
      const fee = await read(COURT, COURT_ABI, "quoteOpen", [p]);
      await pub.simulateContract({
        address: ESCROW,
        abi: ESCROW_ABI,
        functionName: "dispute",
        args: [dealId, evidence, p],
        value: fee,
        account: buyer.address,
      });
      return { panel: p, fee };
    } catch (e) {
      if (String(e).includes("8f4079ff")) continue; // validator shortage → smaller panel
      throw e;
    }
  }
  throw new Error("no validator panel available (min 3)");
}

async function round(n) {
  log(`\n──────── Round ${n} — no human in the loop ────────`);
  const dealId = await read(ESCROW, ESCROW_ABI, "nextDealId");
  const deliverBy = BigInt(Math.floor(Date.now() / 1000) + 86400);
  log(
    `🤖 BuyerAgent → opening escrow deal #${dealId} with SellerAgent (0.01 STT)…`,
  );
  await send(
    ESCROW,
    ESCROW_ABI,
    "createDeal",
    [SELLER, deliverBy],
    parseEther("0.01"),
  );
  log(`🤖 SellerAgent → did NOT deliver by the deadline.`);

  const evidence = `Autonomous BuyerAgent: SellerAgent accepted payment for deal ${dealId} but provided no delivery confirmation and did not respond by the deadline. Requesting a refund.`;
  log(`🤖 BuyerAgent → filing a dispute with machine-generated evidence…`);
  const { panel, fee } = await pickPanel(dealId, evidence);
  await send(ESCROW, ESCROW_ABI, "dispute", [dealId, evidence, panel], fee);
  const [, , , , , caseId] = await read(ESCROW, ESCROW_ABI, "deals", [dealId]);
  log(
    `⚖️  Court → convened a ${panel}-agent validator panel (case #${caseId}); deliberating…`,
  );

  let c;
  for (let i = 0; i < 24; i++) {
    c = await read(COURT, COURT_ABI, "getCase", [caseId]);
    if (Number(c.status) >= 2) break;
    await sleep(5000);
  }
  if (Number(c.status) < 2) throw new Error("panel did not return in time");
  const model = await read(COURT, COURT_ABI, "modelOf", [caseId]);
  log(
    `⚖️  Court → verdict: ${VERDICT[Number(c.verdict)]}  (byte-identical consensus; decided by model ${model})`,
  );

  log(`⏳ Waiting out the appeal window, then finalizing autonomously…`);
  const deadline = Number(
    await read(COURT, COURT_ABI, "appealDeadlineOf", [caseId]),
  );
  while (Math.floor(Date.now() / 1000) <= deadline) await sleep(5000);
  await send(COURT, COURT_ABI, "finalize", [caseId]);
  try {
    await send(REGISTRY, REGISTRY_ABI, "record", [caseId, TOPIC]);
    log(`📚 Verdict recorded as on-chain precedent (case #${caseId}).`);
  } catch {
    log(`📚 (precedent record skipped — already recorded or unavailable)`);
  }

  const pend = await read(ESCROW, ESCROW_ABI, "pending", [buyer.address]);
  if (pend > 0n) {
    await send(ESCROW, ESCROW_ABI, "withdraw");
    log(
      `💰 BuyerAgent → withdrew ${formatEther(pend)} STT. Dispute resolved end-to-end with zero human input.`,
    );
  } else {
    log(
      `💰 Settlement complete (no refund owed to the buyer for this verdict).`,
    );
  }
}

(async () => {
  log(`Verdikt Autonomous Agent Arena — BuyerAgent ${buyer.address}`);
  log(`Escrow ${ESCROW} · Court ${COURT} · ${ROUNDS} round(s)`);
  let failures = 0;
  for (let n = 1; n <= ROUNDS; n++) {
    try {
      await round(n);
    } catch (e) {
      failures++;
      log(`⚠️  Round ${n} failed: ${e.message || e}`);
    }
  }
  if (failures > 0) {
    process.exitCode = 1;
    log(`\n${failures}/${ROUNDS} autonomous round(s) failed.`);
    return;
  }
  log(
    `\n✅ Done. Browse the growing precedent ledger at verdikt.gudman.xyz/app/caselaw.html`,
  );
})();
