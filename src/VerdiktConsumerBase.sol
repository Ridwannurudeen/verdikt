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
    mapping(address => uint256) public pendingRefunds;
    bool private _entered;

    event DisputeOpened(uint256 indexed ref, uint256 indexed caseId);
    event RefundCredited(address indexed to, uint256 amount);
    event RefundWithdrawn(address indexed to, uint256 amount);

    constructor(address court_) {
        require(court_ != address(0), "zero court");
        court = IVerdiktCourt(court_);
    }

    modifier onlyCourt() {
        require(msg.sender == address(court), "only court");
        _;
    }

    modifier nonReentrant() {
        require(!_entered, "reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    /// @notice The court calls this when a case finalizes; routes to your `_settle`.
    function onVerdict(uint256 ref, Verdict verdict) external override onlyCourt nonReentrant {
        _settle(ref, verdict);
    }

    /// @dev Open a dispute for `ref` with `evidence`, paying the court fee from msg.value and refunding
    /// any excess to `refundTo`. Records the caseId <-> ref mapping. Call this from your own
    /// `dispute`-style function after marking your deal disputed.
    function _openDispute(uint256 ref, string memory evidence, address refundTo)
        internal
        nonReentrant
        returns (uint256 caseId)
    {
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");
        _recordRefund(refundTo, fee);
        caseId = court.openCase{value: fee}(ref, evidence);
        _recordDispute(ref, caseId);
    }

    /// @dev As `_openDispute`, but selects the trial panel size so the dispute degrades to the
    /// validator set currently available (in [court.MIN_TRIAL_PANEL, 5]) instead of reverting.
    function _openDispute(uint256 ref, string memory evidence, address refundTo, uint8 trialPanel)
        internal
        nonReentrant
        returns (uint256 caseId)
    {
        uint256 fee = court.quoteOpen(trialPanel);
        require(msg.value >= fee, "fee too low");
        _recordRefund(refundTo, fee);
        caseId = court.openCase{value: fee}(ref, evidence, trialPanel);
        _recordDispute(ref, caseId);
    }

    function _recordDispute(uint256 ref, uint256 caseId) private {
        caseToRef[caseId] = ref;
        refToCase[ref] = caseId;
        emit DisputeOpened(ref, caseId);
    }

    function _recordRefund(address refundTo, uint256 fee) private {
        if (msg.value > fee && refundTo != address(0)) {
            uint256 refund = msg.value - fee;
            pendingRefunds[refundTo] += refund;
            emit RefundCredited(refundTo, refund);
        }
    }

    function withdrawRefund() external nonReentrant returns (uint256 amount) {
        amount = pendingRefunds[msg.sender];
        require(amount > 0, "nothing to withdraw");
        pendingRefunds[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
        emit RefundWithdrawn(msg.sender, amount);
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
