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
        Settled,
        Disputing // evidence-collection phase before the panel is convened (appended last to keep prior values stable)
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
    bool private _entered;

    /// @dev window (seconds) after a dispute is opened during which the counterparty may submit a statement.
    uint64 public responseWindow = 1 hours;
    /// @notice each party's evidence statement for a dispute. dealId => party => statement.
    mapping(uint256 => mapping(address => string)) public statementOf;
    /// @notice timestamp after which a disputed deal can be convened even if a party stayed silent.
    mapping(uint256 => uint64) public responseDeadline;

    event DealCreated(uint256 indexed dealId, address indexed payer, address indexed payee, uint256 amount);
    event Delivered(uint256 indexed dealId);
    event Released(uint256 indexed dealId, address to, uint256 amount);
    event Disputed(uint256 indexed dealId, uint256 indexed caseId, address by);
    event DisputeOpened(uint256 indexed dealId, address indexed by, uint64 responseDeadline);
    event EvidenceSubmitted(uint256 indexed dealId, address indexed by);
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

    function dispute(uint256 dealId, string calldata evidence) external payable nonReentrant {
        Deal storage d = _checkDisputable(dealId);
        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");
        d.status = DealStatus.Disputed;
        _refundExcess(msg.value, fee);
        _recordCase(dealId, court.openCase{value: fee}(dealId, evidence));
    }

    /// @notice Dispute requesting a specific trial panel size (MIN_TRIAL_PANEL..MAX_TRIAL_PANEL).
    /// Lets the caller pick the largest panel the validator set can currently field, so a dispute
    /// can still proceed when the network has fewer than the default validators online.
    function dispute(uint256 dealId, string calldata evidence, uint8 trialPanel) external payable nonReentrant {
        Deal storage d = _checkDisputable(dealId);
        uint256 fee = court.quoteOpen(trialPanel);
        require(msg.value >= fee, "fee too low");
        d.status = DealStatus.Disputed;
        _refundExcess(msg.value, fee);
        _recordCase(dealId, court.openCase{value: fee}(dealId, evidence, trialPanel));
    }

    function _checkDisputable(uint256 dealId) internal view returns (Deal storage d) {
        d = deals[dealId];
        require(msg.sender == d.payer || msg.sender == d.payee, "not a party");
        require(d.status == DealStatus.Funded || d.status == DealStatus.Delivered, "bad status");
    }

    function _recordCase(uint256 dealId, uint256 caseId) internal {
        deals[dealId].caseId = caseId;
        caseToDeal[caseId] = dealId;
        emit Disputed(dealId, caseId, msg.sender);
    }

    // --- two-sided dispute (both parties heard before the panel rules) ---------

    /// @notice Open a two-sided dispute: the opener submits their statement and starts a response
    /// window during which the counterparty may submit theirs. No AI panel rules until convene(),
    /// so both sides can be on record first.
    function openDispute(uint256 dealId, string calldata evidence) external {
        Deal storage d = _checkDisputable(dealId);
        require(bytes(evidence).length > 0, "no evidence");
        d.status = DealStatus.Disputing;
        statementOf[dealId][msg.sender] = evidence;
        uint64 deadline = uint64(block.timestamp + responseWindow);
        responseDeadline[dealId] = deadline;
        emit DisputeOpened(dealId, msg.sender, deadline);
    }

    /// @notice A party adds or updates their statement while the response window is open.
    function submitEvidence(uint256 dealId, string calldata evidence) external {
        Deal storage d = deals[dealId];
        require(d.status == DealStatus.Disputing, "not disputing");
        require(msg.sender == d.payer || msg.sender == d.payee, "not a party");
        require(block.timestamp < responseDeadline[dealId], "window closed");
        require(bytes(evidence).length > 0, "no evidence");
        statementOf[dealId][msg.sender] = evidence;
        emit EvidenceSubmitted(dealId, msg.sender);
    }

    /// @notice Convene the AI panel on BOTH parties' statements. Callable once the response window
    /// has elapsed or both parties have spoken, so a silent counterparty cannot stall settlement.
    function convene(uint256 dealId, uint8 trialPanel) external payable nonReentrant {
        Deal storage d = deals[dealId];
        require(d.status == DealStatus.Disputing, "not disputing");
        require(msg.sender == d.payer || msg.sender == d.payee, "not a party");
        bool bothSpoke =
            bytes(statementOf[dealId][d.payer]).length > 0 && bytes(statementOf[dealId][d.payee]).length > 0;
        require(block.timestamp >= responseDeadline[dealId] || bothSpoke, "window open");
        uint256 fee = court.quoteOpen(trialPanel);
        require(msg.value >= fee, "fee too low");
        d.status = DealStatus.Disputed;
        _refundExcess(msg.value, fee);
        _recordCase(dealId, court.openCase{value: fee}(dealId, _combinedStatement(dealId, d), trialPanel));
    }

    function _combinedStatement(uint256 dealId, Deal storage d) internal view returns (string memory) {
        string memory pe = statementOf[dealId][d.payer];
        string memory ye = statementOf[dealId][d.payee];
        if (bytes(pe).length == 0) pe = "(no statement submitted)";
        if (bytes(ye).length == 0) ye = "(no statement submitted)";
        // Clean each party's statement so it cannot forge the section headers and spoof the
        // counterparty's submission (audit: label injection in the two-sided combined statement).
        return string.concat("BUYER (payer) states:\n", _clean(pe), "\n\nSELLER (payee) states:\n", _clean(ye));
    }

    /// @dev Neutralize newlines and angle brackets in a party statement so it cannot inject a fake
    /// "SELLER/BUYER states:" header line (or the court's evidence fence). Deterministic.
    function _clean(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; i++) {
            bytes1 ch = b[i];
            if (ch == 0x0a || ch == 0x0d || ch == 0x3c || ch == 0x3e) b[i] = 0x20; // \n \r < > -> space
        }
        return string(b);
    }

    function appeal(uint256 dealId, string calldata newEvidence) external payable nonReentrant {
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

        _refundExcess(msg.value, stake + agentDep);
        court.appeal{value: agentDep}(d.caseId, newEvidence);
        emit AppealFiled(dealId, msg.sender, stake, cv.verdict);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override nonReentrant {
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

    function withdraw() external nonReentrant returns (uint256 amount) {
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

    function setResponseWindow(uint64 w) external onlyOwner {
        responseWindow = w;
    }

    function setKeeperCutBps(uint256 bps) external onlyOwner {
        require(bps <= 2000, "cut too high"); // cap the treasury cut so a slash can't be fully redirected
        keeperCutBps = bps;
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "zero treasury");
        treasury = t;
    }

    receive() external payable {}
}
