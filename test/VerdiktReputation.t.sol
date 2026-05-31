// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {VerdiktReputation} from "../src/VerdiktReputation.sol";
import {Verdict, CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktReputationTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;
    VerdiktReputation rep;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        rep = new VerdiktReputation(address(court));
        vm.deal(payer, 100 ether);
        vm.deal(payee, 100 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 dealId) internal view returns (uint256 c) {
        (,,,,, c) = escrow.deals(dealId);
    }

    /// @notice Open a deal, dispute it, deliver `verdict`, then finalize so the court case is Final.
    function _driveToFinal(string memory verdict) internal returns (uint256 caseId) {
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(payee, uint64(block.timestamp + 1 days));

        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "evidence");

        platform.fireSuccess(_lastReq(), verdict);
        caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Final), "case not final");
    }

    function test_record_payeeWins() public {
        uint256 caseId = _driveToFinal("PAYEE");

        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
        rep.record(caseId, payer, VerdiktReputation.Side.Payer);

        VerdiktReputation.Rep memory rPayee = rep.reputationOf(payee);
        assertEq(rPayee.disputes, 1);
        assertEq(rPayee.wins, 1);
        assertEq(rPayee.losses, 0);
        assertEq(rPayee.splits, 0);
        assertEq(rPayee.lastCaseId, caseId);

        VerdiktReputation.Rep memory rPayer = rep.reputationOf(payer);
        assertEq(rPayer.disputes, 1);
        assertEq(rPayer.wins, 0);
        assertEq(rPayer.losses, 1);
        assertEq(rPayer.splits, 0);

        assertEq(rep.scoreOf(payee), int256(2));
        assertEq(rep.scoreOf(payer), int256(-1));
    }

    function test_record_payerWins() public {
        uint256 caseId = _driveToFinal("PAYER");

        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
        rep.record(caseId, payer, VerdiktReputation.Side.Payer);

        assertEq(rep.reputationOf(payer).wins, 1);
        assertEq(rep.reputationOf(payer).losses, 0);
        assertEq(rep.reputationOf(payee).losses, 1);
        assertEq(rep.reputationOf(payee).wins, 0);

        assertEq(rep.scoreOf(payer), int256(2));
        assertEq(rep.scoreOf(payee), int256(-1));
    }

    function test_record_split() public {
        uint256 caseId = _driveToFinal("SPLIT");

        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
        rep.record(caseId, payer, VerdiktReputation.Side.Payer);

        VerdiktReputation.Rep memory rPayee = rep.reputationOf(payee);
        assertEq(rPayee.disputes, 1);
        assertEq(rPayee.splits, 1);
        assertEq(rPayee.wins, 0);
        assertEq(rPayee.losses, 0);

        VerdiktReputation.Rep memory rPayer = rep.reputationOf(payer);
        assertEq(rPayer.splits, 1);
        assertEq(rPayer.wins, 0);
        assertEq(rPayer.losses, 0);

        assertEq(rep.scoreOf(payee), int256(0));
        assertEq(rep.scoreOf(payer), int256(0));
    }

    function test_record_accumulatesAcrossCases() public {
        uint256 c1 = _driveToFinal("PAYEE"); // payee wins
        rep.record(c1, payee, VerdiktReputation.Side.Payee);

        uint256 c2 = _driveToFinal("PAYEE"); // payee wins again
        rep.record(c2, payee, VerdiktReputation.Side.Payee);

        uint256 c3 = _driveToFinal("PAYER"); // payee loses
        rep.record(c3, payee, VerdiktReputation.Side.Payee);

        VerdiktReputation.Rep memory r = rep.reputationOf(payee);
        assertEq(r.disputes, 3);
        assertEq(r.wins, 2);
        assertEq(r.losses, 1);
        assertEq(r.lastCaseId, c3);
        assertEq(rep.scoreOf(payee), int256(3)); // 2*2 - 1
    }

    function test_recorded_flag() public {
        uint256 caseId = _driveToFinal("PAYEE");
        assertFalse(rep.recorded(caseId, payee));
        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
        assertTrue(rep.recorded(caseId, payee));
    }

    function test_doubleRecord_reverts() public {
        uint256 caseId = _driveToFinal("PAYEE");
        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
        vm.expectRevert(bytes("already recorded"));
        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
    }

    function test_record_revertsForZeroParty() public {
        uint256 caseId = _driveToFinal("PAYEE");
        vm.expectRevert(bytes("zero party"));
        rep.record(caseId, address(0), VerdiktReputation.Side.Payee);
    }

    function test_nonFinalCase_reverts() public {
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(payee, uint64(block.timestamp + 1 days));
        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "evidence");
        platform.fireSuccess(_lastReq(), "PAYEE"); // Ruled, not Final (no finalize)

        uint256 caseId = _caseId(dealId);
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Ruled));

        vm.expectRevert(bytes("not final"));
        rep.record(caseId, payee, VerdiktReputation.Side.Payee);
    }
}
