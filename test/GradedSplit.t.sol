// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Graded SPLIT % verdicts: the court can apportion a disputed amount in 25% buckets
/// (PAYER/SPLIT25/SPLIT50/SPLIT75/PAYEE), and VerdiktEscrow settles to that ratio. Graded mode is
/// opt-in so the default 3-label determinism behavior is unchanged.
contract GradedSplitTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;

    address owner = address(this);
    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        vm.deal(payer, 1000 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    /// @dev Create a deal, dispute it, and deliver `label` as the panel verdict. Returns dealId + caseId.
    function _disputeAndRule(uint256 amount, string memory label) internal returns (uint256 dealId, uint256 caseId) {
        vm.prank(payer);
        dealId = escrow.createDeal{value: amount}(payee, uint64(block.timestamp + 1 days));
        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "partial delivery");
        platform.fireSuccess(_lastReq(), label);
        (,,,,, caseId) = escrow.deals(dealId);
    }

    function _settle(uint256 caseId) internal {
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    // --- court-level: labels parse to the right basis points ------------------

    function test_splitBps_mapping() public {
        court.setGradedSplit(true);
        (, uint256 cPayer) = _disputeAndRule(1 ether, "PAYER");
        (, uint256 c25) = _disputeAndRule(1 ether, "SPLIT25");
        (, uint256 c50) = _disputeAndRule(1 ether, "SPLIT50");
        (, uint256 c75) = _disputeAndRule(1 ether, "SPLIT75");
        (, uint256 cPayee) = _disputeAndRule(1 ether, "PAYEE");

        assertEq(court.splitBps(cPayer), 0);
        assertEq(court.splitBps(c25), 2500);
        assertEq(court.splitBps(c50), 5000);
        assertEq(court.splitBps(c75), 7500);
        assertEq(court.splitBps(cPayee), 10000);
    }

    function test_gradedLabels_resolveToSplitVerdict() public {
        court.setGradedSplit(true);
        (, uint256 c25) = _disputeAndRule(1 ether, "SPLIT25");
        (, uint256 c75) = _disputeAndRule(1 ether, "SPLIT75");
        assertEq(uint8(court.getCase(c25).verdict), uint8(Verdict.SPLIT));
        assertEq(uint8(court.getCase(c75).verdict), uint8(Verdict.SPLIT));
    }

    // --- backward compatibility: default mode is unchanged --------------------

    function test_default_isNotGraded() public view {
        assertEq(court.gradedSplit(), false);
    }

    function test_plainSplit_isFiftyFifty() public {
        (, uint256 caseId) = _disputeAndRule(1 ether, "SPLIT");
        assertEq(court.splitBps(caseId), 5000);
        _settle(caseId);
        assertEq(escrow.pending(payer), 0.5 ether);
        assertEq(escrow.pending(payee), 0.5 ether);
    }

    // --- end-to-end graded settlement -----------------------------------------

    function test_escrow_settlesGraded_75toPayee() public {
        court.setGradedSplit(true);
        (, uint256 caseId) = _disputeAndRule(1 ether, "SPLIT75");
        _settle(caseId);
        assertEq(escrow.pending(payee), 0.75 ether);
        assertEq(escrow.pending(payer), 0.25 ether);
    }

    function test_escrow_settlesGraded_25toPayee() public {
        court.setGradedSplit(true);
        (, uint256 caseId) = _disputeAndRule(1 ether, "SPLIT25");
        _settle(caseId);
        assertEq(escrow.pending(payee), 0.25 ether);
        assertEq(escrow.pending(payer), 0.75 ether);
    }

    /// @dev Any graded ratio conserves the full amount and routes the remainder wei to the payee.
    function testFuzz_gradedSplit_conservesAmount(uint256 amount, uint8 bucket) public {
        amount = bound(amount, 1 wei, 100 ether);
        string memory label = ["SPLIT25", "SPLIT50", "SPLIT75"][bound(bucket, 0, 2)];
        uint16 bps = [uint16(2500), 5000, 7500][bound(bucket, 0, 2)];

        court.setGradedSplit(true);
        (, uint256 caseId) = _disputeAndRule(amount, label);
        _settle(caseId);

        uint256 toPayer = escrow.pending(payer);
        uint256 toPayee = escrow.pending(payee);
        assertEq(toPayer, (amount * (10000 - bps)) / 10000, "payer share");
        assertEq(toPayer + toPayee, amount, "conserves amount");
    }

    // --- admin guard ----------------------------------------------------------

    function test_setGradedSplit_onlyOwner() public {
        vm.prank(payer);
        vm.expectRevert(bytes("not owner"));
        court.setGradedSplit(true);
    }
}
