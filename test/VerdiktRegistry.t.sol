// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {VerdiktRegistry} from "../src/VerdiktRegistry.sol";
import {IVerdiktCourt, Verdict, CaseStatus, CaseView} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktRegistryTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;
    VerdiktRegistry registry;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");

    bytes32 constant TOPIC = keccak256("escrow/non-delivery");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        registry = new VerdiktRegistry(address(court));
        vm.deal(payer, 100 ether);
        vm.deal(payee, 100 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 dealId) internal view returns (uint256 c) {
        (,,,,, c) = escrow.deals(dealId);
    }

    function _newDeal() internal returns (uint256 dealId) {
        vm.prank(payer);
        dealId = escrow.createDeal{value: 1 ether}(payee, uint64(block.timestamp + 1 days));
    }

    function _dispute(uint256 dealId, address who, string memory ev) internal {
        uint256 fee = court.quoteOpen();
        vm.prank(who);
        escrow.dispute{value: fee}(dealId, ev);
    }

    /// @notice Drive a dispute all the way to a FINAL court case and return its caseId.
    function _finalCase(string memory verdict) internal returns (uint256 caseId) {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "goods delivered as agreed");
        platform.fireSuccess(_lastReq(), verdict);
        caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    function test_record_matchesCourt() public {
        uint256 caseId = _finalCase("PAYEE");
        CaseView memory cv = court.getCase(caseId);

        registry.record(caseId, TOPIC);

        VerdiktRegistry.Ruling memory r = registry.getRuling(caseId);
        assertEq(r.caseId, caseId);
        assertEq(r.consumer, cv.consumer);
        assertEq(r.escrowRef, cv.escrowRef);
        assertEq(uint8(r.verdict), uint8(cv.verdict));
        assertEq(r.receiptId, cv.receiptId);
        assertEq(r.rulingTime, cv.rulingTime);
        assertEq(r.topic, TOPIC);
        assertTrue(registry.isRecorded(caseId));
    }

    function test_record_indexesTopicAndConsumer() public {
        uint256 caseId = _finalCase("SPLIT");
        CaseView memory cv = court.getCase(caseId);
        registry.record(caseId, TOPIC);

        uint256[] memory byT = registry.rulingsByTopic(TOPIC);
        assertEq(byT.length, 1);
        assertEq(byT[0], caseId);

        uint256[] memory byC = registry.rulingsByConsumer(cv.consumer);
        assertEq(byC.length, 1);
        assertEq(byC[0], caseId);
    }

    function test_record_permissionless() public {
        uint256 caseId = _finalCase("PAYER");
        vm.prank(makeAddr("keeper"));
        registry.record(caseId, TOPIC);
        assertTrue(registry.isRecorded(caseId));
    }

    function test_countAndPagination() public {
        uint256 c1 = _finalCase("PAYEE");
        uint256 c2 = _finalCase("PAYER");
        uint256 c3 = _finalCase("SPLIT");
        registry.record(c1, TOPIC);
        registry.record(c2, TOPIC);
        registry.record(c3, keccak256("other"));

        assertEq(registry.rulingsCount(), 3);

        uint256[] memory first = registry.allRulings(0, 2);
        assertEq(first.length, 2);
        assertEq(first[0], c1);
        assertEq(first[1], c2);

        uint256[] memory rest = registry.allRulings(2, 10);
        assertEq(rest.length, 1);
        assertEq(rest[0], c3);

        uint256[] memory none = registry.allRulings(3, 10);
        assertEq(none.length, 0);
    }

    function test_doubleRecordReverts() public {
        uint256 caseId = _finalCase("PAYEE");
        registry.record(caseId, TOPIC);
        vm.expectRevert(bytes("already recorded"));
        registry.record(caseId, TOPIC);
    }

    function test_recordRuledNotFinalReverts() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev");
        platform.fireSuccess(_lastReq(), "PAYEE"); // case is now Ruled, not Final
        uint256 caseId = _caseId(dealId);

        CaseView memory cv = court.getCase(caseId);
        assertEq(uint8(cv.status), uint8(CaseStatus.Ruled));

        vm.expectRevert(bytes("not final"));
        registry.record(caseId, TOPIC);
    }

    function test_recordPendingNotFinalReverts() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev"); // dispatched, awaiting panel -> Pending
        uint256 caseId = _caseId(dealId);

        CaseView memory cv = court.getCase(caseId);
        assertEq(uint8(cv.status), uint8(CaseStatus.Pending));

        vm.expectRevert(bytes("not final"));
        registry.record(caseId, TOPIC);
    }
}
