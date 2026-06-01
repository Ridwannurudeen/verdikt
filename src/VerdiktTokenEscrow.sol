// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict, CaseStatus, CaseView} from "./interfaces/IVerdiktCourt.sol";

/// @notice Minimal ERC-20 surface used by the escrow (no OpenZeppelin in this repo).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title VerdiktTokenEscrow
/// @notice A two-party escrow denominated in an ERC-20 token that resolves disputes through
/// VerdiktCourt's AI panel. The deal value and appeal stakes are token; the court's agent fees
/// remain native STT (forwarded as msg.value). Settlement is pull-payment: verdicts credit a
/// token ledger and parties withdraw, so an unaccepting recipient can never strand a deal.
contract VerdiktTokenEscrow is IVerdiktConsumer {
    IVerdiktCourt public immutable court;
    IERC20 public immutable token;
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
        bool active;
    }

    uint256 public nextDealId = 1;
    mapping(uint256 => Deal) public deals;
    mapping(uint256 => AppealInfo) public appeals;
    /// @notice court caseId => dealId, so onVerdict can route by escrowRef.
    mapping(uint256 => uint256) public caseToDeal;
    /// @notice token amounts owed to each address, claimable via withdraw().
    mapping(address => uint256) public pending;
    /// @notice native STT refunds from court-fee overpayment, claimable via withdrawNative().
    mapping(address => uint256) public nativePending;

    event DealCreated(uint256 indexed dealId, address indexed payer, address indexed payee, uint256 amount);
    event Delivered(uint256 indexed dealId);
    event Released(uint256 indexed dealId, address to, uint256 amount);
    event Disputed(uint256 indexed dealId, uint256 indexed caseId, address by);
    event AppealFiled(uint256 indexed dealId, address indexed appellant, uint256 stake, Verdict preAppealVerdict);
    event DealSettled(uint256 indexed dealId, Verdict verdict, uint256 toPayer, uint256 toPayee);
    event StakeSlashed(uint256 indexed dealId, address loser, address winner, uint256 toWinner, uint256 toTreasury);
    event StakeReturned(uint256 indexed dealId, address appellant, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event NativeRefundCredited(address indexed to, uint256 amount);
    event NativeWithdrawn(address indexed to, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address court_, address treasury_, address token_) {
        court = IVerdiktCourt(court_);
        token = IERC20(token_);
        owner = msg.sender;
        treasury = treasury_;
    }

    // --- lifecycle ------------------------------------------------------------

    function createDeal(address payee, uint256 amount, uint64 deliverBy) external returns (uint256 dealId) {
        require(amount > 0, "no funds");
        require(payee != address(0) && payee != msg.sender, "bad payee");
        _safeTransferFrom(msg.sender, address(this), amount);
        dealId = nextDealId++;
        deals[dealId] = Deal({
            payer: msg.sender, payee: payee, amount: amount, status: DealStatus.Funded, deliverBy: deliverBy, caseId: 0
        });
        emit DealCreated(dealId, msg.sender, payee, amount);
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
        pending[d.payee] += amount;
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
        require(msg.value >= agentDep, "value too low");

        _safeTransferFrom(msg.sender, address(this), stake);

        appeals[dealId] = AppealInfo({appellant: msg.sender, stake: stake, preAppealVerdict: cv.verdict, active: true});

        court.appeal{value: agentDep}(d.caseId, newEvidence);
        _refundExcess(msg.value, agentDep);
        emit AppealFiled(dealId, msg.sender, stake, cv.verdict);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override {
        require(msg.sender == address(court), "only court");
        Deal storage d = deals[escrowRef];
        require(d.status == DealStatus.Disputed, "not disputed");

        uint256 amount = d.amount;
        d.status = DealStatus.Settled;

        (uint256 toPayer, uint256 toPayee) = _split(verdict, amount);
        if (toPayer > 0) pending[d.payer] += toPayer;
        if (toPayee > 0) pending[d.payee] += toPayee;
        emit DealSettled(escrowRef, verdict, toPayer, toPayee);

        AppealInfo storage a = appeals[escrowRef];
        if (a.active) {
            a.active = false;
            if (verdict == a.preAppealVerdict) {
                // appeal failed: slash stake to the appellant's counterparty (minus treasury cut)
                address winner = a.appellant == d.payer ? d.payee : d.payer;
                uint256 cut = (a.stake * keeperCutBps) / 10000;
                uint256 toWinner = a.stake - cut;
                if (cut > 0) pending[treasury] += cut;
                if (toWinner > 0) pending[winner] += toWinner;
                emit StakeSlashed(escrowRef, a.appellant, winner, toWinner, cut);
            } else {
                // overturned: return stake to the appellant
                pending[a.appellant] += a.stake;
                emit StakeReturned(escrowRef, a.appellant, a.stake);
            }
        }
    }

    // --- withdrawal -----------------------------------------------------------

    function withdraw() external {
        uint256 amt = pending[msg.sender];
        require(amt > 0, "nothing to withdraw");
        pending[msg.sender] = 0;
        _safeTransfer(msg.sender, amt);
        emit Withdrawn(msg.sender, amt);
    }

    function withdrawNative() external returns (uint256 amount) {
        amount = nativePending[msg.sender];
        require(amount > 0, "nothing to withdraw");
        nativePending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
        emit NativeWithdrawn(msg.sender, amount);
    }

    // --- views ----------------------------------------------------------------

    function _loser(Deal storage d, Verdict verdict) internal view returns (address) {
        if (verdict == Verdict.PAYEE) return d.payer;
        if (verdict == Verdict.PAYER) return d.payee;
        return address(0); // SPLIT has no single loser
    }

    function _split(Verdict verdict, uint256 amount) internal pure returns (uint256 toPayer, uint256 toPayee) {
        if (verdict == Verdict.PAYEE) return (0, amount);
        if (verdict == Verdict.PAYER) return (amount, 0);
        // SPLIT (or NONE fallback treated as split to avoid stranding funds)
        uint256 half = amount / 2;
        return (half, amount - half);
    }

    // --- internals ------------------------------------------------------------

    function _refundExcess(uint256 sent, uint256 used) internal {
        if (sent > used) {
            nativePending[msg.sender] += sent - used;
            emit NativeRefundCredited(msg.sender, sent - used);
        }
    }

    function _safeTransfer(address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transferFrom failed");
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
