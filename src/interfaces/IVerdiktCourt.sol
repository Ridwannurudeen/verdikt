// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Verdict labels. Index into the allowedValues array passed to the LLM agent
/// (PAYEE=1, PAYER=2, SPLIT=3); NONE=0 means unparseable / not yet ruled.
enum Verdict {
    NONE,
    PAYEE,
    PAYER,
    SPLIT
}

enum CaseStatus {
    None,
    Pending, // awaiting an agent panel verdict
    Ruled, // a verdict is in; appeal window may be open
    Final, // settled, consumer notified
    Errored // agent panel failed/timed out
}

struct CaseView {
    address consumer;
    uint256 escrowRef;
    uint8 round;
    CaseStatus status;
    Verdict verdict;
    uint256 receiptId;
    uint64 rulingTime;
}

/// @notice Any contract that consumes the court implements this to receive the final verdict.
interface IVerdiktConsumer {
    function onVerdict(uint256 escrowRef, Verdict verdict) external;
}

/// @notice The reusable AI-jury arbitration primitive.
interface IVerdiktCourt {
    function openCase(uint256 escrowRef, string calldata evidence) external payable returns (uint256 caseId);
    function appeal(uint256 caseId, string calldata newEvidence) external payable;
    function retry(uint256 caseId) external payable;
    function finalize(uint256 caseId) external;

    function quoteOpen() external view returns (uint256);
    function quoteAppeal(uint256 caseId) external view returns (uint256);
    function getCase(uint256 caseId) external view returns (CaseView memory);
    /// @notice Payee share of the disputed amount in basis points for a ruled case:
    /// PAYEE = 10000, PAYER = 0, SPLIT = 5000 (or a graded value when graded mode is on).
    function splitBps(uint256 caseId) external view returns (uint16);
    function appealWindow() external view returns (uint64);
    function MAX_ROUND() external view returns (uint8);
}
