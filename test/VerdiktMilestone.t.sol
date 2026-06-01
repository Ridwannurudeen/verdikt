// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktMilestone} from "../src/VerdiktMilestone.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktMilestoneTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktMilestone milestone;

    address client = makeAddr("client");
    address freelancer = makeAddr("freelancer");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        milestone = new VerdiktMilestone(address(court), treasury);
        vm.deal(client, 100 ether);
        vm.deal(freelancer, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 milestoneId) internal view returns (uint256 c) {
        (,,,,, c) = milestone.milestones(milestoneId);
    }

    function _status(uint256 milestoneId) internal view returns (VerdiktMilestone.MilestoneStatus st) {
        (,,, st,,) = milestone.milestones(milestoneId);
    }

    function _newMilestone() internal returns (uint256 milestoneId) {
        vm.prank(client);
        milestoneId = milestone.createMilestone{value: 1 ether}(freelancer, uint64(block.timestamp + 14 days));
    }

    function _dispute(uint256 milestoneId, address who, string memory ev) internal {
        uint256 fee = court.quoteOpen();
        vm.prank(who);
        milestone.dispute{value: fee}(milestoneId, ev);
    }

    function _finalize(uint256 milestoneId) internal {
        uint256 caseId = _caseId(milestoneId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    function test_payeeWins_paysFreelancer() public {
        uint256 id = _newMilestone();
        _dispute(id, freelancer, "work delivered on spec");
        platform.fireSuccess(_lastReq(), "PAYEE");
        _finalize(id);

        assertEq(milestone.pending(freelancer), 1 ether);
        assertEq(milestone.pending(client), 0);
        assertEq(uint8(_status(id)), uint8(VerdiktMilestone.MilestoneStatus.Settled));

        uint256 before = freelancer.balance;
        vm.prank(freelancer);
        milestone.withdraw();
        assertEq(freelancer.balance, before + 1 ether);
        assertEq(milestone.pending(freelancer), 0);
    }

    function test_payerWins_refundsClient() public {
        uint256 id = _newMilestone();
        _dispute(id, client, "deliverable never arrived");
        platform.fireSuccess(_lastReq(), "PAYER");
        _finalize(id);

        // PAYER = refund the client.
        assertEq(milestone.pending(client), 1 ether);
        assertEq(milestone.pending(freelancer), 0);

        uint256 before = client.balance;
        vm.prank(client);
        milestone.withdraw();
        assertEq(client.balance, before + 1 ether);
    }

    function test_split_halfEach() public {
        uint256 id = _newMilestone();
        _dispute(id, client, "half the scope delivered");
        platform.fireSuccess(_lastReq(), "SPLIT");
        _finalize(id);

        assertEq(milestone.pending(client), 0.5 ether);
        assertEq(milestone.pending(freelancer), 0.5 ether);

        uint256 clientBefore = client.balance;
        uint256 freelancerBefore = freelancer.balance;
        vm.prank(client);
        milestone.withdraw();
        vm.prank(freelancer);
        milestone.withdraw();
        assertEq(client.balance, clientBefore + 0.5 ether);
        assertEq(freelancer.balance, freelancerBefore + 0.5 ether);
    }

    function test_gradedSplit75_paysFreelancerThreeQuarters() public {
        court.setGradedSplit(true);
        uint256 id = _newMilestone();
        _dispute(id, client, "mostly complete");
        platform.fireSuccess(_lastReq(), "SPLIT75");
        _finalize(id);

        assertEq(milestone.pending(client), 0.25 ether);
        assertEq(milestone.pending(freelancer), 0.75 ether);
    }

    function test_dispute_onlyParty() public {
        uint256 id = _newMilestone();
        uint256 fee = court.quoteOpen();
        vm.prank(stranger);
        vm.expectRevert(bytes("not a party"));
        milestone.dispute{value: fee}(id, "x");
    }

    function test_onVerdict_onlyCourt() public {
        uint256 id = _newMilestone();
        vm.expectRevert(bytes("only court"));
        milestone.onVerdict(id, Verdict.PAYEE);
    }

    function test_withdraw_nothing() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("nothing to withdraw"));
        milestone.withdraw();
    }

    function test_dispute_refundsExcess() public {
        uint256 id = _newMilestone();
        uint256 fee = court.quoteOpen();
        uint256 before = client.balance;
        vm.prank(client);
        milestone.dispute{value: fee + 1 ether}(id, "ev");
        assertEq(client.balance, before - fee - 1 ether);
        assertEq(milestone.pending(client), 1 ether);

        vm.prank(client);
        milestone.withdraw();
        assertEq(client.balance, before - fee);
    }
}
