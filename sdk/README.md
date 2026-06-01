# Integrate the Verdikt court in <50 lines

`VerdiktCourt` is a reusable on-chain arbitration primitive: your contract (or autonomous
agent) opens a case with evidence, a panel of LLM-inference agents returns a binding
verdict (`PAYEE` / `PAYER` / `SPLIT`) under Majority consensus, and the court calls you
back with the result. Both parties can be contracts — there is no EOA required anywhere in
the settlement path.

All signatures below are the real ones from
[`src/interfaces/IVerdiktCourt.sol`](../src/interfaces/IVerdiktCourt.sol). Nothing is invented.

## The interfaces you depend on

```solidity
enum Verdict { NONE, PAYEE, PAYER, SPLIT }
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

## A minimal consumer

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict, CaseStatus, CaseView}
    from "verdikt/interfaces/IVerdiktCourt.sol";

contract MyAgent is IVerdiktConsumer {
    IVerdiktCourt public immutable court;
    mapping(uint256 => uint256) public caseToRef; // caseId => your reference

    constructor(address court_) {
        court = IVerdiktCourt(court_);
    }

    // 1. OPEN — quote the fee, then open a case with your evidence string.
    function open(uint256 myRef, string calldata evidence) external returns (uint256 caseId) {
        uint256 fee = court.quoteOpen();
        caseId = court.openCase{value: fee}(myRef, evidence);
        caseToRef[caseId] = myRef;
    }

    // 2. APPEAL — only while status == Ruled and within appealWindow. Quote covers the larger panel.
    function appeal(uint256 caseId, string calldata newEvidence) external {
        uint256 fee = court.quoteAppeal(caseId);
        court.appeal{value: fee}(caseId, newEvidence);
    }

    // 3. READ — poll the case any time (e.g. a keeper checks status before finalize).
    function statusOf(uint256 caseId) external view returns (CaseStatus, Verdict) {
        CaseView memory cv = court.getCase(caseId);
        return (cv.status, cv.verdict);
    }

    // 4. CALLBACK — the court calls this when the case finalizes. Settle here.
    function onVerdict(uint256 escrowRef, Verdict verdict) external override {
        require(msg.sender == address(court), "only court");
        // credit a pull-payment ledger (recommended) instead of pushing ETH, so a
        // counterparty that reverts on receipt can never brick settlement:
        // if (verdict == Verdict.PAYER) pending[payerOf[escrowRef]] += amountOf[escrowRef];
    }
}
```

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
