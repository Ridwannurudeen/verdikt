// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VerdiktConsumerBase} from "../VerdiktConsumerBase.sol";
import {Verdict} from "../interfaces/IVerdiktCourt.sol";

/// @title SimpleEscrow
/// @notice The reference integration: a complete two-party escrow on VerdiktCourt's AI jury in well
/// under 50 lines, built on VerdiktConsumerBase. Teaching example — no appeals/stakes; see
/// VerdiktEscrow for the production version. SPLIT (incl. graded) and UNDECIDABLE are handled for free
/// by `_payeeShareBps`.
contract SimpleEscrow is VerdiktConsumerBase {
    struct Deal {
        address payer;
        address payee;
        uint256 amount;
        bool settled;
    }

    mapping(uint256 => Deal) public deals;
    mapping(address => uint256) public pending;
    uint256 public nextId = 1;

    constructor(address court_) VerdiktConsumerBase(court_) {}

    function createDeal(address payee) external payable returns (uint256 id) {
        require(msg.value > 0 && payee != address(0) && payee != msg.sender, "bad deal");
        id = nextId++;
        deals[id] = Deal(msg.sender, payee, msg.value, false);
    }

    function dispute(uint256 id, string calldata evidence) external payable {
        Deal storage d = deals[id];
        require(msg.sender == d.payer || msg.sender == d.payee, "not a party");
        require(!d.settled, "settled");
        _openDispute(id, evidence, msg.sender);
    }

    function _settle(uint256 ref, Verdict verdict) internal override {
        Deal storage d = deals[ref];
        require(!d.settled, "settled");
        d.settled = true;
        uint256 toPayee = (d.amount * _payeeShareBps(ref, verdict)) / 10000;
        pending[d.payee] += toPayee;
        pending[d.payer] += d.amount - toPayee;
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
