// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktConsumerBase
/// @notice Inherit this to plug any protocol into VerdiktCourt's AI jury in a few lines. It handles
/// the boilerplate every consumer otherwise repeats: storing the court, guarding the callback,
/// opening a dispute (quote + fee + refund), mapping court caseId <-> your reference, and resolving a
/// verdict (graded SPLIT + UNDECIDABLE aware) into a payee basis-point share. A child just implements
/// `_settle(ref, verdict)` and its own deal lifecycle.
abstract contract VerdiktConsumerBase is IVerdiktConsumer {
    IVerdiktCourt public immutable court;

    /// @notice court caseId => your dispute reference, and the reverse.
    mapping(uint256 => uint256) public caseToRef;
    mapping(uint256 => uint256) public refToCase;

    event DisputeOpened(uint256 indexed ref, uint256 indexed caseId);

    constructor(address court_) {
        require(court_ != address(0), "zero court");
        court = IVerdiktCourt(court_);
    }

    modifier onlyCourt() {
        require(msg.sender == address(court), "only court");
        _;
    }

    /// @notice The court calls this when a case finalizes; routes to your `_settle`.
    function onVerdict(uint256 ref, Verdict verdict) external override onlyCourt {
        _settle(ref, verdict);
    }

    /// @dev Open a dispute for `ref` with `evidence`, paying the court fee from msg.value and refunding
    /// any excess to `refundTo`. Records the caseId <-> ref mapping. Call this from your own
    /// `dispute`-style function after marking your deal disputed.
    function _openDispute(uint256 ref, string memory evidence, address refundTo) internal returns (uint256 caseId) {
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");
        caseId = court.openCase{value: fee}(ref, evidence);
        caseToRef[caseId] = ref;
        refToCase[ref] = caseId;
        emit DisputeOpened(ref, caseId);
        if (msg.value > fee && refundTo != address(0)) {
            (bool ok,) = refundTo.call{value: msg.value - fee}("");
            require(ok, "refund failed");
        }
    }

    /// @dev Resolve any verdict to the payee's share of the disputed amount in basis points:
    /// PAYEE = 10000, SPLIT = the court's graded share, PAYER / UNDECIDABLE / NONE = 0 (payer keeps all).
    function _payeeShareBps(uint256 ref, Verdict verdict) internal view returns (uint256) {
        if (verdict == Verdict.PAYEE) return 10000;
        if (verdict == Verdict.SPLIT) return court.splitBps(refToCase[ref]);
        return 0;
    }

    /// @dev Implement settlement. Use `_payeeShareBps(ref, verdict)` to split funds.
    function _settle(uint256 ref, Verdict verdict) internal virtual;
}
