// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VerdiktConsumerBase} from "../VerdiktConsumerBase.sol";
import {Verdict} from "../interfaces/IVerdiktCourt.sol";

/// @title ServiceSLA
/// @notice Reference integration: a pay-per-period service agreement whose SLA-breach disputes are
/// settled by the AI jury — "judgment as an oracle" for the agent economy. A client prepays a provider
/// (which may be an autonomous agent) for a service period under stated SLA terms; if the client claims
/// a breach (downtime, missed metrics), either party disputes and the panel reads the incident evidence
/// and rules: PAYEE = provider met the SLA (release the fee), PAYER = breach (refund the client),
/// SPLIT = partial service credit. Built on VerdiktConsumerBase — the whole integration is the
/// `dispute`/`accept` lifecycle plus a one-line `_settle`. The provider is the "payee", client the "payer".
contract ServiceSLA is VerdiktConsumerBase {
    struct Agreement {
        address client;
        address provider;
        uint256 fee; // prepaid service fee held in escrow
        string sla; // human-readable SLA terms, e.g. "99.9% uptime over the period"
        bool settled;
    }

    mapping(uint256 => Agreement) public agreements;
    mapping(address => uint256) public pending;
    uint256 public nextId = 1;

    event AgreementOpened(uint256 indexed id, address indexed client, address indexed provider, uint256 fee);
    event Settled(uint256 indexed id, uint256 toProvider, uint256 toClient);

    constructor(address court_) VerdiktConsumerBase(court_) {}

    /// @notice Client prepays a provider for a service period under `sla` terms.
    function open(address provider, string calldata sla) external payable returns (uint256 id) {
        require(msg.value > 0 && provider != address(0) && provider != msg.sender, "bad agreement");
        id = nextId++;
        agreements[id] = Agreement(msg.sender, provider, msg.value, sla, false);
        emit AgreementOpened(id, msg.sender, provider, msg.value);
    }

    /// @notice Happy path: the client confirms the service was delivered and releases the fee.
    function accept(uint256 id) external {
        Agreement storage a = agreements[id];
        require(msg.sender == a.client, "only client");
        require(!a.settled, "settled");
        a.settled = true;
        pending[a.provider] += a.fee;
        emit Settled(id, a.fee, 0);
    }

    /// @notice Either party disputes an SLA breach; the AI jury rules on the incident evidence.
    /// `trialPanel` in [court.MIN_TRIAL_PANEL, 5] degrades to the validators currently available.
    function dispute(uint256 id, string calldata evidence, uint8 trialPanel) external payable {
        Agreement storage a = agreements[id];
        require(msg.sender == a.client || msg.sender == a.provider, "not a party");
        require(!a.settled, "settled");
        _openDispute(id, evidence, msg.sender, trialPanel);
    }

    /// @dev PAYEE = provider met the SLA (gets the fee); PAYER / UNDECIDABLE = breach, refund the client;
    /// SPLIT = graded service credit. All handled by `_payeeShareBps`.
    function _settle(uint256 ref, Verdict verdict) internal override {
        Agreement storage a = agreements[ref];
        require(!a.settled, "settled");
        a.settled = true;
        uint256 toProvider = (a.fee * _payeeShareBps(ref, verdict)) / 10000;
        pending[a.provider] += toProvider;
        pending[a.client] += a.fee - toProvider;
        emit Settled(ref, toProvider, a.fee - toProvider);
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
