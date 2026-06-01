// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict, CaseStatus, CaseView} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktEscrow
/// @notice A two-party escrow that resolves disputes through VerdiktCourt's AI panel.
/// The novel layer: the losing party can appeal by posting a stake; if the larger
/// appeal panel upholds the original verdict, the stake is slashed to the winner.
/// Settlement uses pull payments so a reverting recipient cannot brick finalization.
contract VerdiktEscrow is IVerdiktConsumer {
    IVerdiktCourt public immutable court;
    address public owner;
    address public treasury;

    /// @dev appeal stake as a fraction of the deal amount (bps). 1000 = 10%.
    uint256 public appealStakeBps = 1000;
    /// @dev cut of a slashed stake routed to the treasury (bps of the stake). 500 = 5%.
    uint256 public keeperCutBps = 500;

    enum DealStatus {
        None,
        Funded,
        Delivered,
        Disputed,
        Settled
    }

    struct Deal {
        address payer;
        address payee;
        uint256 amount;
        DealStatus status;
        uint64 deliverBy;
        uint256 caseId;
    }

    struct AppealInfo {
        address appellant;
        uint256 stake;
        Verdict preAppealVerdict;
        uint16 preAppealPayeeBps;
        bool active;
    }

    uint256 public nextDealId = 1;
    mapping(uint256 => Deal) public deals;
    mapping(uint256 => AppealInfo) public appeals;
    /// @notice court caseId => dealId, so onVerdict can route by escrowRef.
    mapping(uint256 => uint256) public caseToDeal;
    /// @notice pull-payment ledger: settled value waiting for its owner to withdraw.
    mapping(address => uint256) public pending;

    event DealCreated(uint256 indexed dealId, address indexed payer, address indexed payee, uint256 amount);
    event Delivered(uint256 indexed dealId);
    event Released(uint256 indexed dealId, address to, uint256 amount);
    event Disputed(uint256 indexed dealId, uint256 indexed caseId, address by);
    event AppealFiled(uint256 indexed dealId, address indexed appellant, uint256 stake, Verdict preAppealVerdict);
    event DealSettled(uint256 indexed dealId, Verdict verdict, uint256 toPayer, uint256 toPayee);
    event StakeSlashed(uint256 indexed dealId, address loser, address winner, uint256 toWinner, uint256 toTreasury);
    event StakeReturned(uint256 indexed dealId, address appellant, uint256 amount);
    event Credited(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address court_, address treasury_) {
        require(court_ != address(0), "zero court");
        require(treasury_ != address(0), "zero treasury");
        court = IVerdiktCourt(court_);
        owner = msg.sender;
        treasury = treasury_;
    }

    // --- lifecycle ------------------------------------------------------------

    function createDeal(address payee, uint64 deliverBy) external payable returns (uint256 dealId) {
        require(msg.value > 0, "no funds");
        require(payee != address(0) && payee != msg.sender, "bad payee");
        dealId = nextDealId++;
        deals[dealId] = Deal({
            payer: msg.sender,
            payee: payee,
            amount: msg.value,
            status: DealStatus.Funded,
            deliverBy: deliverBy,
            caseId: 0
        });
        emit DealCreated(dealId, msg.sender, payee, msg.value);
    }

    function markDelivered(uint256 dealId) external {
        Deal storage d = deals[dealId];
        require(msg.sender == d.payee, "only payee");
        require(d.status == DealStatus.Funded, "bad status");
        d.status = DealStatus.Delivered;
        emit Delivered(dealId);
    }

    /// @notice Payer releases anytime; anyone may release after deliverBy once delivered (keeper auto-release).
    function release(uint256 dealId) external {
        Deal storage d = deals[dealId];
        require(d.status == DealStatus.Funded || d.status == DealStatus.Delivered, "bad status");
        require(
            msg.sender == d.payer || (d.status == DealStatus.Delivered && block.timestamp > d.deliverBy),
            "not allowed yet"
        );
        uint256 amount = d.amount;
        d.status = DealStatus.Settled;
        _credit(d.payee, amount);
        emit Released(dealId, d.payee, amount);
    }

    // --- dispute + appeal -----------------------------------------------------

    function dispute(uint256 dealId, string calldata evidence) external payable {
        Deal storage d = deals[dealId];
        require(msg.sender == d.payer || msg.sender == d.payee, "not a party");
        require(d.status == DealStatus.Funded || d.status == DealStatus.Delivered, "bad status");
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");

        d.status = DealStatus.Disputed;
        uint256 caseId = court.openCase{value: fee}(dealId, evidence);
        d.caseId = caseId;
        caseToDeal[caseId] = dealId;
        _refundExcess(msg.value, fee);
        emit Disputed(dealId, caseId, msg.sender);
    }

    function appeal(uint256 dealId, string calldata newEvidence) external payable {
        Deal storage d = deals[dealId];
        require(d.status == DealStatus.Disputed, "not disputed");
        require(!appeals[dealId].active, "already appealed");

        CaseView memory cv = court.getCase(d.caseId);
        require(cv.status == CaseStatus.Ruled, "no verdict yet");

        address loser = _loser(d, cv.verdict);
        if (cv.verdict == Verdict.SPLIT) {
            require(msg.sender == d.payer || msg.sender == d.payee, "not a party");
        } else {
            require(msg.sender == loser, "only losing party");
        }

        uint256 stake = (d.amount * appealStakeBps) / 10000;
        require(stake > 0, "stake too low");
        uint256 agentDep = court.quoteAppeal(d.caseId);
        require(msg.value >= stake + agentDep, "value too low");

        appeals[dealId] = AppealInfo({
            appellant: msg.sender,
            stake: stake,
            preAppealVerdict: cv.verdict,
            preAppealPayeeBps: court.splitBps(d.caseId),
            active: true
        });

        court.appeal{value: agentDep}(d.caseId, newEvidence);
        _refundExcess(msg.value, stake + agentDep);
        emit AppealFiled(dealId, msg.sender, stake, cv.verdict);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override {
        require(msg.sender == address(court), "only court");
        Deal storage d = deals[escrowRef];
        require(d.status == DealStatus.Disputed, "not disputed");

        uint256 amount = d.amount;
        d.status = DealStatus.Settled;

        (uint256 toPayer, uint256 toPayee) = _split(verdict, amount, d.caseId);
        _credit(d.payer, toPayer);
        _credit(d.payee, toPayee);
        emit DealSettled(escrowRef, verdict, toPayer, toPayee);

        AppealInfo storage a = appeals[escrowRef];
        if (a.active) {
            a.active = false;
            if (_sameRuling(verdict, court.splitBps(d.caseId), a.preAppealVerdict, a.preAppealPayeeBps)) {
                // appeal failed: slash stake to the appellant's counterparty (minus treasury cut)
                address winner = a.appellant == d.payer ? d.payee : d.payer;
                uint256 cut = (a.stake * keeperCutBps) / 10000;
                uint256 toWinner = a.stake - cut;
                _credit(treasury, cut);
                _credit(winner, toWinner);
                emit StakeSlashed(escrowRef, a.appellant, winner, toWinner, cut);
            } else {
                // overturned: return stake to the appellant
                _credit(a.appellant, a.stake);
                emit StakeReturned(escrowRef, a.appellant, a.stake);
            }
        }
    }

    // --- pull payments --------------------------------------------------------

    function withdraw() external returns (uint256 amount) {
        amount = pending[msg.sender];
        require(amount > 0, "nothing to withdraw");
        pending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }

    // --- views ----------------------------------------------------------------

    function _loser(Deal storage d, Verdict verdict) internal view returns (address) {
        if (verdict == Verdict.PAYEE) return d.payer;
        if (verdict == Verdict.PAYER || verdict == Verdict.UNDECIDABLE) return d.payee;
        return address(0); // SPLIT has no single loser
    }

    /// @dev SPLIT honors the court's graded payee share (basis points); plain SPLIT returns 5000 (50/50).
    /// UNDECIDABLE (panel abstained) refunds the payer — burden of proof is on the claimant.
    function _split(Verdict verdict, uint256 amount, uint256 caseId)
        internal
        view
        returns (uint256 toPayer, uint256 toPayee)
    {
        if (verdict == Verdict.PAYEE) return (0, amount);
        if (verdict == Verdict.PAYER || verdict == Verdict.UNDECIDABLE) return (amount, 0);
        // payer's floored share; the payee receives the remainder wei (never stranded).
        toPayer = (amount * (10000 - court.splitBps(caseId))) / 10000;
        toPayee = amount - toPayer;
    }

    function _sameRuling(Verdict current, uint16 currentBps, Verdict previous, uint16 previousBps)
        internal
        pure
        returns (bool)
    {
        if (current != previous) return false;
        return current != Verdict.SPLIT || currentBps == previousBps;
    }

    // --- internals ------------------------------------------------------------

    function _credit(address to, uint256 amount) internal {
        if (amount > 0) {
            pending[to] += amount;
            emit Credited(to, amount);
        }
    }

    function _refundExcess(uint256 sent, uint256 used) internal {
        if (sent > used) _credit(msg.sender, sent - used);
    }

    // --- admin ----------------------------------------------------------------

    function setAppealStakeBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "bps");
        appealStakeBps = bps;
    }

    function setKeeperCutBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "bps");
        keeperCutBps = bps;
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "zero treasury");
        treasury = t;
    }

    receive() external payable {}
}
