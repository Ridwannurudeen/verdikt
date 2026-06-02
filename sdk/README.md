# Integrate the Verdikt court in <50 lines

`VerdiktCourt` is a reusable on-chain arbitration primitive: your contract (or autonomous
agent) opens a case with evidence, a panel of LLM-inference agents returns a binding
verdict (`PAYEE` / `PAYER` / `SPLIT`) under Majority consensus, and the court calls you
back with the result. Both parties can be contracts — there is no EOA required anywhere in
the settlement path.

All signatures below are the real ones from
[`src/interfaces/IVerdiktCourt.sol`](../src/interfaces/IVerdiktCourt.sol). Nothing is invented.

## Install (Foundry)

```bash
forge install Ridwannurudeen/verdikt
```

Then inherit [`VerdiktConsumerBase`](../src/VerdiktConsumerBase.sol) — it handles the court wiring,
the callback guard, opening a dispute (quote + fee + refund), the caseId↔ref mapping, and resolving a
verdict (graded SPLIT + UNDECIDABLE aware) into a payee basis-point share. You implement `_settle`.

## The interfaces you depend on

```solidity
enum Verdict { NONE, PAYEE, PAYER, SPLIT, UNDECIDABLE } // UNDECIDABLE = panel abstained
enum CaseStatus { None, Pending, Ruled, Final, Errored }

struct CaseView {
    address    consumer;    // who opened the case
    uint256    escrowRef;   // your opaque reference (e.g. a dealId)
    uint8      round;       // 0 = trial, 1 = appeal
    CaseStatus status;      // Pending -> Ruled -> Final (or Errored)
    Verdict    verdict;     // set once status == Ruled
    uint256    receiptId;   // off-chain receipt of the jurors' reasoning
    uint64     rulingTime;  // when the verdict landed (appeal window starts here)
}

interface IVerdiktConsumer {
    function onVerdict(uint256 escrowRef, Verdict verdict) external;
}

interface IVerdiktCourt {
    function openCase(uint256 escrowRef, string calldata evidence) external payable returns (uint256 caseId);
    function appeal(uint256 caseId, string calldata newEvidence) external payable;
    function finalize(uint256 caseId) external;
    function quoteOpen() external view returns (uint256);
    function quoteAppeal(uint256 caseId) external view returns (uint256);
    function getCase(uint256 caseId) external view returns (CaseView memory);
    function splitBps(uint256 caseId) external view returns (uint16);
    function appealDeadlineOf(uint256 caseId) external view returns (uint64);
    function appealWindow() external view returns (uint64);
}
```

## A complete consumer, on the base (the easy path)

This is a full two-party escrow on the AI jury — graded SPLIT and UNDECIDABLE handled for free. It is
the real [`src/examples/SimpleEscrow.sol`](../src/examples/SimpleEscrow.sol), validated end-to-end in
[`test/SimpleEscrow.t.sol`](../test/SimpleEscrow.t.sol).

```solidity
import {VerdiktConsumerBase} from "verdikt/VerdiktConsumerBase.sol";
import {Verdict} from "verdikt/interfaces/IVerdiktCourt.sol";

contract SimpleEscrow is VerdiktConsumerBase {
    struct Deal { address payer; address payee; uint256 amount; bool settled; }
    mapping(uint256 => Deal) public deals;
    mapping(address => uint256) public pending;
    uint256 public nextId = 1;

    constructor(address court_) VerdiktConsumerBase(court_) {}

    function createDeal(address payee) external payable returns (uint256 id) {
        id = nextId++;
        deals[id] = Deal(msg.sender, payee, msg.value, false);
    }

    function dispute(uint256 id, string calldata evidence) external payable {
        // base quotes the fee, opens the case, maps caseId<->id, refunds the excess
        _openDispute(id, evidence, msg.sender);
    }

    // the court calls onVerdict -> _settle (base guards the callback for you)
    function _settle(uint256 ref, Verdict verdict) internal override {
        Deal storage d = deals[ref];
        d.settled = true;
        uint256 toPayee = (d.amount * _payeeShareBps(ref, verdict)) / 10000; // graded/UNDECIDABLE aware
        pending[d.payee] += toPayee;
        pending[d.payer] += d.amount - toPayee; // pull payments -> can't be bricked
    }

    function withdraw() external {
        uint256 amt = pending[msg.sender];
        pending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "withdraw failed");
    }
}
```

Prefer the raw interface? `import {IVerdiktCourt, IVerdiktConsumer, Verdict} from "verdikt/interfaces/IVerdiktCourt.sol"`
and implement `onVerdict` + the dispute flow yourself.

## JS / TS SDK (frontends + agents)

[`sdk/index.mjs`](./index.mjs) is a thin viem client:

```js
import { createVerdiktClient, payeeShareBps, VERDICT } from "verdikt/sdk/index.mjs";

const verdikt = createVerdiktClient({ publicClient, court: "0x..." });
const fee = await verdikt.quoteOpen();
const c = await verdikt.getCase(1);            // -> { verdictLabel, statusLabel, ... }
const bps = await payeeShareBps(verdikt, 1);   // graded-SPLIT aware payee share
const unwatch = verdikt.watchVerdicts((v) => console.log(v.caseId, v.verdict, v.receiptId));
```

## Autonomous agents & decentralized keepers

[`sdk/agent.mjs`](./agent.mjs) lets an agent (with a wallet) act in the court — file appeals, run as a
keeper, and earn bounties:

```js
import { createVerdiktAgent } from "verdikt/sdk/agent.mjs";
const agent = createVerdiktAgent({ publicClient, walletClient, account, court: "0x..." });

await agent.runKeeper();                         // finalize every case whose appeal window has passed
await agent.appeal(caseId, "new evidence");      // contest a ruling (auto-quotes the larger panel)
await agent.finalizeForBounty(bounty, caseId);   // settle a case AND claim the keeper bounty
```

`finalize` is permissionless, so anyone can run a keeper. [`VerdiktKeeperBounty`](../src/VerdiktKeeperBounty.sol)
adds the incentive: anyone funds a bounty to get a case settled, and the keeper that settles it takes
the pot — a trustless market for liveness, no Court change required.

## Lifecycle

1. **Open.** `quoteOpen()` returns the exact fee; pass it as `msg.value` to `openCase`. The
   court convenes the trial panel (5 agents) and returns a `caseId`.
2. **Wait for the ruling.** The panel callback sets `status` to `Ruled` and fills `verdict` +
   `rulingTime`. Read it with `getCase(caseId)`. If `verdict == SPLIT`, read
   `splitBps(caseId)`; a graded court may return 2500/5000/7500 rather than assuming 50/50.
3. **(Optional) appeal.** While `status == Ruled` and `block.timestamp <= appealDeadlineOf(caseId)`,
   call `appeal{value: quoteAppeal(caseId)}(caseId, newEvidence)`. A larger panel (9 agents)
   re-tries with the appended evidence. `appeal` is restricted to the case's original `consumer`.
4. **Finalize.** Once the appeal window has passed (or the final round is in), anyone — a
   keeper, the counterparty, an agent — calls `finalize(caseId)`. The court flips `status` to
   `Final` and invokes your `onVerdict(escrowRef, verdict)`. This is permissionless, so no
   human is needed to settle.

## Settle without bricking — use pull payments

`onVerdict` runs inside `finalize`. If you **push** ETH to the parties there and one party
is a contract that reverts on receipt, `finalize` reverts and the case is stuck. Instead,
**credit a `pending[address]` ledger in `onVerdict` and expose a `withdraw()`** that each
party calls to pull its own funds. See
[`src/VerdiktAgentEscrow.sol`](../src/VerdiktAgentEscrow.sol) for the reference pattern and
[`test/AgentToAgentDemo.t.sol`](../test/AgentToAgentDemo.t.sol) for two contract agents
settling a dispute end-to-end with no EOA in the loop.

## Notes

- `escrowRef` is opaque to the court — use it to map a case back to your own state (a dealId,
  a policyId, a hash).
- Quotes can change with panel pricing; always read `quoteOpen()` / `quoteAppeal()` at call
  time rather than hardcoding a fee.
- If the panel fails or returns an unparseable result, `status` becomes `Errored`; the
  consumer can `retry(caseId)` with a fresh deposit.
