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
    bool private _entered;

    event GrantCreated(uint256 indexed grantId, address indexed funder, address indexed grantee, uint256 amount);
    event Disputed(uint256 indexed grantId, uint256 indexed caseId, address by);
    event GrantSettled(uint256 indexed grantId, Verdict verdict, uint256 toFunder, uint256 toGrantee);
    event Withdrawn(address indexed who, uint256 amount);

    modifier nonReentrant() {
        require(!_entered, "reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address court_, address treasury_) {
        require(court_ != address(0), "zero court");
        require(treasury_ != address(0), "zero treasury");
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

    function dispute(uint256 grantId, string calldata evidence) external payable nonReentrant {
        Grant storage g = grants[grantId];
        require(msg.sender == g.funder || msg.sender == g.grantee, "not a party");
        require(g.status == GrantStatus.Funded, "bad status");
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");

        g.status = GrantStatus.Disputed;
        _refundExcess(msg.value, fee);
        uint256 caseId = court.openCase{value: fee}(grantId, evidence);
        g.caseId = caseId;
        caseToGrant[caseId] = grantId;
        emit Disputed(grantId, caseId, msg.sender);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override nonReentrant {
        require(msg.sender == address(court), "only court");
        Grant storage g = grants[escrowRef];
        require(g.status == GrantStatus.Disputed, "not disputed");

        uint256 amount = g.amount;
        g.status = GrantStatus.Settled;

        (uint256 toFunder, uint256 toGrantee) = _split(verdict, amount, g.caseId);
        if (toFunder > 0) pending[g.funder] += toFunder;
        if (toGrantee > 0) pending[g.grantee] += toGrantee;
        emit GrantSettled(escrowRef, verdict, toFunder, toGrantee);
    }

    // --- settlement -----------------------------------------------------------

    function withdraw() external nonReentrant {
        uint256 amount = pending[msg.sender];
        require(amount > 0, "nothing to withdraw");
        pending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    // --- internals ------------------------------------------------------------

    /// @dev PAYER claws the grant back to the DAO funder; PAYEE releases to the grantee.
    /// UNDECIDABLE (panel abstained) claws back to the funder — burden of proof is on the grantee.
    function _split(Verdict verdict, uint256 amount, uint256 caseId)
        internal
        view
        returns (uint256 toFunder, uint256 toGrantee)
    {
        if (verdict == Verdict.PAYER || verdict == Verdict.UNDECIDABLE) return (amount, 0);
        if (verdict == Verdict.PAYEE) return (0, amount);
        toFunder = (amount * (10000 - court.splitBps(caseId))) / 10000;
        toGrantee = amount - toFunder;
    }

    function _refundExcess(uint256 sent, uint256 used) internal {
        if (sent > used) pending[msg.sender] += sent - used;
    }

    receive() external payable {}
}
