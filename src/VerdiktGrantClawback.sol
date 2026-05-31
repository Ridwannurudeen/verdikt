// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktGrantClawback
/// @notice A DAO grant escrow that resolves milestone disputes through VerdiktCourt's AI panel.
/// The DAO (funder) escrows a grant for a grantee against a milestone deadline. If the grantee
/// fails to deliver, either party disputes and the court rules:
///   PAYER = clawback to the DAO (funder refunded), PAYEE = release to grantee, SPLIT = half each.
/// Settlement is pull-payment: the verdict credits `pending`, and each party withdraws itself,
/// so a contract counterparty can never brick the settlement of the other side.
contract VerdiktGrantClawback is IVerdiktConsumer {
    IVerdiktCourt public immutable court;
    address public treasury;

    enum GrantStatus {
        None,
        Funded,
        Disputed,
        Settled
    }

    struct Grant {
        address funder; // the DAO; PAYER verdict claws back here
        address grantee; // PAYEE verdict releases here
        uint256 amount;
        GrantStatus status;
        uint64 milestoneBy;
        uint256 caseId;
    }

    uint256 public nextGrantId = 1;
    mapping(uint256 => Grant) public grants;
    /// @notice court caseId => grantId, so onVerdict can route by escrowRef.
    mapping(uint256 => uint256) public caseToGrant;
    /// @notice pull-payment balances credited at settlement.
    mapping(address => uint256) public pending;

    event GrantCreated(uint256 indexed grantId, address indexed funder, address indexed grantee, uint256 amount);
    event Disputed(uint256 indexed grantId, uint256 indexed caseId, address by);
    event GrantSettled(uint256 indexed grantId, Verdict verdict, uint256 toFunder, uint256 toGrantee);
    event Withdrawn(address indexed who, uint256 amount);

    constructor(address court_, address treasury_) {
        court = IVerdiktCourt(court_);
        treasury = treasury_;
    }

    // --- lifecycle ------------------------------------------------------------

    function createGrant(address grantee, uint64 milestoneBy) external payable returns (uint256 grantId) {
        require(msg.value > 0, "no funds");
        require(grantee != address(0) && grantee != msg.sender, "bad grantee");
        grantId = nextGrantId++;
        grants[grantId] = Grant({
            funder: msg.sender,
            grantee: grantee,
            amount: msg.value,
            status: GrantStatus.Funded,
            milestoneBy: milestoneBy,
            caseId: 0
        });
        emit GrantCreated(grantId, msg.sender, grantee, msg.value);
    }

    // --- dispute --------------------------------------------------------------

    function dispute(uint256 grantId, string calldata evidence) external payable {
        Grant storage g = grants[grantId];
        require(msg.sender == g.funder || msg.sender == g.grantee, "not a party");
        require(g.status == GrantStatus.Funded, "bad status");
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");

        g.status = GrantStatus.Disputed;
        uint256 caseId = court.openCase{value: fee}(grantId, evidence);
        g.caseId = caseId;
        caseToGrant[caseId] = grantId;
        _refundExcess(msg.value, fee);
        emit Disputed(grantId, caseId, msg.sender);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override {
        require(msg.sender == address(court), "only court");
        Grant storage g = grants[escrowRef];
        require(g.status == GrantStatus.Disputed, "not disputed");

        uint256 amount = g.amount;
        g.status = GrantStatus.Settled;

        (uint256 toFunder, uint256 toGrantee) = _split(verdict, amount);
        if (toFunder > 0) pending[g.funder] += toFunder;
        if (toGrantee > 0) pending[g.grantee] += toGrantee;
        emit GrantSettled(escrowRef, verdict, toFunder, toGrantee);
    }

    // --- settlement -----------------------------------------------------------

    function withdraw() external {
        uint256 amount = pending[msg.sender];
        require(amount > 0, "nothing to withdraw");
        pending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    // --- internals ------------------------------------------------------------

    /// @dev PAYER claws the grant back to the DAO funder; PAYEE releases to the grantee.
    function _split(Verdict verdict, uint256 amount) internal pure returns (uint256 toFunder, uint256 toGrantee) {
        if (verdict == Verdict.PAYER) return (amount, 0);
        if (verdict == Verdict.PAYEE) return (0, amount);
        // SPLIT (or NONE fallback treated as split to avoid stranding funds)
        uint256 half = amount / 2;
        return (half, amount - half);
    }

    function _refundExcess(uint256 sent, uint256 used) internal {
        if (sent > used) pending[msg.sender] += sent - used;
    }

    receive() external payable {}
}
