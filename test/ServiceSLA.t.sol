// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {ServiceSLA} from "../src/examples/ServiceSLA.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Exercises the ServiceSLA reference integration end-to-end: an SLA-breach dispute settled by
/// the AI jury, proving provider-met-SLA / breach / partial-credit all resolve via VerdiktConsumerBase.
contract ServiceSLATest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    ServiceSLA sla;

    address client = makeAddr("client");
    address provider = makeAddr("provider");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        sla = new ServiceSLA(address(court));
        vm.deal(client, 100 ether);
    }

    function _disputeAndRule(string memory label) internal returns (uint256 id, uint256 caseId) {
        vm.prank(client);
        id = sla.open{value: 1 ether}(provider, "99.9% uptime over the period");
        uint256 fee = court.quoteOpen(3);
        vm.prank(client);
        sla.dispute{value: fee}(id, "incident: provider was down 6h, breaching the 99.9% SLA", 3);
        platform.fireSuccess(platform.nextId() - 1, label);
        caseId = sla.refToCase(id);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    function test_providerMetSLA_getsFee() public {
        _disputeAndRule("PAYEE");
        assertEq(sla.pending(provider), 1 ether);
        assertEq(sla.pending(client), 0);
    }

    function test_breach_refundsClient() public {
        _disputeAndRule("PAYER");
        assertEq(sla.pending(client), 1 ether);
        assertEq(sla.pending(provider), 0);
    }

    function test_partialCredit_gradedSplit() public {
        court.setGradedSplit(true);
        _disputeAndRule("SPLIT75");
        assertEq(sla.pending(provider), 0.75 ether);
        assertEq(sla.pending(client), 0.25 ether);
    }

    function test_accept_releasesToProvider() public {
        vm.prank(client);
        uint256 id = sla.open{value: 1 ether}(provider, "99.9% uptime");
        vm.prank(client);
        sla.accept(id);
        assertEq(sla.pending(provider), 1 ether);
        assertEq(sla.pending(client), 0);
    }
}
