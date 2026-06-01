// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktMilestone
/// @notice A freelance milestone escrow that resolves delivery disputes through VerdiktCourt's
/// AI panel. The client escrows payment for a freelancer against a due date. On dispute the
/// court rules:
///   PAYEE = pay the freelancer, PAYER = refund the client, SPLIT = half each.
/// Settlement is pull-payment: the verdict credits `pending`, and each party withdraws itself,
/// so a contract counterparty can never brick the settlement of the other side.
contract VerdiktMilestone is IVerdiktConsumer {
    IVerdiktCourt public immutable court;
    address public treasury;

    enum MilestoneStatus {
        None,
        Funded,
        Disputed,
        Settled
    }

    struct Milestone {
        address client; // PAYER verdict refunds here
        address freelancer; // PAYEE verdict pays here
        uint256 amount;
        MilestoneStatus status;
        uint64 dueBy;
        uint256 caseId;
    }

    uint256 public nextMilestoneId = 1;
    mapping(uint256 => Milestone) public milestones;
    /// @notice court caseId => milestoneId, so onVerdict can route by escrowRef.
    mapping(uint256 => uint256) public caseToMilestone;
    /// @notice pull-payment balances credited at settlement.
    mapping(address => uint256) public pending;

    event MilestoneCreated(
        uint256 indexed milestoneId, address indexed client, address indexed freelancer, uint256 amount
    );
    event Disputed(uint256 indexed milestoneId, uint256 indexed caseId, address by);
    event MilestoneSettled(uint256 indexed milestoneId, Verdict verdict, uint256 toClient, uint256 toFreelancer);
    event Withdrawn(address indexed who, uint256 amount);

    constructor(address court_, address treasury_) {
        require(court_ != address(0), "zero court");
        require(treasury_ != address(0), "zero treasury");
        court = IVerdiktCourt(court_);
        treasury = treasury_;
    }

    // --- lifecycle ------------------------------------------------------------

    function createMilestone(address freelancer, uint64 dueBy) external payable returns (uint256 milestoneId) {
        require(msg.value > 0, "no funds");
        require(freelancer != address(0) && freelancer != msg.sender, "bad freelancer");
        milestoneId = nextMilestoneId++;
        milestones[milestoneId] = Milestone({
            client: msg.sender,
            freelancer: freelancer,
            amount: msg.value,
            status: MilestoneStatus.Funded,
            dueBy: dueBy,
            caseId: 0
        });
        emit MilestoneCreated(milestoneId, msg.sender, freelancer, msg.value);
    }

    // --- dispute --------------------------------------------------------------

    function dispute(uint256 milestoneId, string calldata evidence) external payable {
        Milestone storage m = milestones[milestoneId];
        require(msg.sender == m.client || msg.sender == m.freelancer, "not a party");
        require(m.status == MilestoneStatus.Funded, "bad status");
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");

        m.status = MilestoneStatus.Disputed;
        uint256 caseId = court.openCase{value: fee}(milestoneId, evidence);
        m.caseId = caseId;
        caseToMilestone[caseId] = milestoneId;
        _refundExcess(msg.value, fee);
        emit Disputed(milestoneId, caseId, msg.sender);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override {
        require(msg.sender == address(court), "only court");
        Milestone storage m = milestones[escrowRef];
        require(m.status == MilestoneStatus.Disputed, "not disputed");

        uint256 amount = m.amount;
        m.status = MilestoneStatus.Settled;

        (uint256 toClient, uint256 toFreelancer) = _split(verdict, amount, m.caseId);
        if (toClient > 0) pending[m.client] += toClient;
        if (toFreelancer > 0) pending[m.freelancer] += toFreelancer;
        emit MilestoneSettled(escrowRef, verdict, toClient, toFreelancer);
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

    /// @dev PAYER refunds the client; PAYEE pays the freelancer.
    /// UNDECIDABLE (panel abstained) refunds the client — burden of proof is on the freelancer.
    function _split(Verdict verdict, uint256 amount, uint256 caseId)
        internal
        view
        returns (uint256 toClient, uint256 toFreelancer)
    {
        if (verdict == Verdict.PAYER || verdict == Verdict.UNDECIDABLE) return (amount, 0);
        if (verdict == Verdict.PAYEE) return (0, amount);
        toClient = (amount * (10000 - court.splitBps(caseId))) / 10000;
        toFreelancer = amount - toClient;
    }

    function _refundExcess(uint256 sent, uint256 used) internal {
        if (sent > used) pending[msg.sender] += sent - used;
    }

    receive() external payable {}
}
