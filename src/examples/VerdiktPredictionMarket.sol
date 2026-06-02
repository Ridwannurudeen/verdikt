// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VerdiktConsumerBase} from "../VerdiktConsumerBase.sol";
import {Verdict} from "../interfaces/IVerdiktCourt.sol";

/// @title VerdiktPredictionMarket
/// @notice Judgment-as-an-oracle: a binary prediction market whose SUBJECTIVE outcome is resolved by
/// VerdiktCourt's AI jury rather than a trusted admin. Users stake YES/NO on a question
/// ("did the team ship by the deadline?", "was the announcement bullish?"); after close, anyone routes
/// the resolution to the court with evidence. The verdict maps PAYEE = YES, PAYER = NO, SPLIT/
/// UNDECIDABLE = VOID (refund). Winners claim the whole pool pro-rata; a void refunds every staker.
/// Built on VerdiktConsumerBase — the court integration is a handful of lines.
contract VerdiktPredictionMarket is VerdiktConsumerBase {
    enum Status {
        Open,
        Disputed,
        Resolved
    }
    enum Outcome {
        Unresolved,
        Yes,
        No,
        Void
    }

    struct Market {
        string question;
        uint64 closesAt;
        uint256 yesPool;
        uint256 noPool;
        Status status;
        Outcome outcome;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => uint256)) public yesStake;
    mapping(uint256 => mapping(address => uint256)) public noStake;
    mapping(address => uint256) public pending;
    uint256 public nextMarketId = 1;

    event MarketCreated(uint256 indexed id, string question, uint64 closesAt);
    event Staked(uint256 indexed id, address indexed who, bool yes, uint256 amount);
    event Resolved(uint256 indexed id, Outcome outcome);
    event Claimed(uint256 indexed id, address indexed who, uint256 amount);

    constructor(address court_) VerdiktConsumerBase(court_) {}

    function createMarket(string calldata question, uint64 closesAt) external returns (uint256 id) {
        require(closesAt > block.timestamp, "bad close");
        id = nextMarketId++;
        markets[id] = Market(question, closesAt, 0, 0, Status.Open, Outcome.Unresolved);
        emit MarketCreated(id, question, closesAt);
    }

    function stakeYes(uint256 id) external payable {
        _stake(id, true);
    }

    function stakeNo(uint256 id) external payable {
        _stake(id, false);
    }

    function _stake(uint256 id, bool yes) internal {
        Market storage m = markets[id];
        require(m.status == Status.Open && block.timestamp < m.closesAt, "staking closed");
        require(msg.value > 0, "no stake");
        if (yes) {
            yesStake[id][msg.sender] += msg.value;
            m.yesPool += msg.value;
        } else {
            noStake[id][msg.sender] += msg.value;
            m.noPool += msg.value;
        }
        emit Staked(id, msg.sender, yes, msg.value);
    }

    /// @notice After close, route the resolution to the court with evidence. Pay the court fee as value.
    function resolve(uint256 id, string calldata evidence) external payable {
        Market storage m = markets[id];
        require(m.status == Status.Open && block.timestamp >= m.closesAt, "not closeable");
        m.status = Status.Disputed;
        _openDispute(id, evidence, msg.sender);
    }

    function _settle(uint256 ref, Verdict verdict) internal override {
        Market storage m = markets[ref];
        require(m.status == Status.Disputed, "not disputed");
        m.status = Status.Resolved;
        if (verdict == Verdict.PAYEE && m.yesPool > 0) {
            m.outcome = Outcome.Yes;
        } else if (verdict == Verdict.PAYER && m.noPool > 0) {
            m.outcome = Outcome.No;
        } else {
            // SPLIT/UNDECIDABLE, or a win for a side nobody staked -> refund everyone
            m.outcome = Outcome.Void;
        }
        emit Resolved(ref, m.outcome);
    }

    /// @notice Claim winnings (pro-rata of the whole pool) or, on a void, your own stake back.
    function claim(uint256 id) external {
        Market storage m = markets[id];
        require(m.status == Status.Resolved, "unresolved");
        uint256 total = m.yesPool + m.noPool;
        uint256 payout;
        if (m.outcome == Outcome.Yes) {
            uint256 s = yesStake[id][msg.sender];
            require(s > 0, "no winning stake");
            yesStake[id][msg.sender] = 0;
            payout = (total * s) / m.yesPool;
        } else if (m.outcome == Outcome.No) {
            uint256 s = noStake[id][msg.sender];
            require(s > 0, "no winning stake");
            noStake[id][msg.sender] = 0;
            payout = (total * s) / m.noPool;
        } else {
            uint256 s = yesStake[id][msg.sender] + noStake[id][msg.sender];
            require(s > 0, "nothing to claim");
            yesStake[id][msg.sender] = 0;
            noStake[id][msg.sender] = 0;
            payout = s;
        }
        pending[msg.sender] += payout;
        emit Claimed(id, msg.sender, payout);
    }

    function withdraw() external {
        uint256 amt = pending[msg.sender];
        require(amt > 0, "nothing to withdraw");
        pending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "withdraw failed");
    }

    receive() external payable {}
}
