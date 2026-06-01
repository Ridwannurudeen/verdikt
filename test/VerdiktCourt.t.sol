// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {IVerdiktCourt, IVerdiktConsumer, Verdict, CaseStatus, CaseView} from "../src/interfaces/IVerdiktCourt.sol";
import {Request, Response, ResponseStatus} from "../src/interfaces/IAgentRequester.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract MockConsumer is IVerdiktConsumer {
    IVerdiktCourt public court;
    Verdict public lastVerdict;
    uint256 public lastRef;
    uint256 public calls;

    constructor(IVerdiktCourt c) {
        court = c;
    }

    function open(uint256 ref, string calldata ev) external payable returns (uint256) {
        return court.openCase{value: msg.value}(ref, ev);
    }

    function doAppeal(uint256 caseId, string calldata ev) external payable {
        court.appeal{value: msg.value}(caseId, ev);
    }

    function doRetry(uint256 caseId) external payable {
        court.retry{value: msg.value}(caseId);
    }

    function withdrawCourtRefund() external returns (uint256) {
        return VerdiktCourt(payable(address(court))).withdrawRefund();
    }

    function onVerdict(uint256 ref, Verdict v) external override {
        lastRef = ref;
        lastVerdict = v;
        calls++;
    }

    receive() external payable {}
}

contract VerdiktCourtTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    MockConsumer consumer;

    receive() external payable {}

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        consumer = new MockConsumer(IVerdiktCourt(address(court)));
        vm.deal(address(this), 100 ether);
        vm.deal(address(consumer), 100 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function test_openCase_dispatches() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(42, "buyer never shipped");
        CaseView memory cv = court.getCase(caseId);
        assertEq(uint8(cv.status), uint8(CaseStatus.Pending));
        assertEq(cv.escrowRef, 42);
        assertTrue(platform.hasRequest(_lastReq()));
    }

    function test_openCase_revertsLowDeposit() public {
        uint256 q = court.quoteOpen();
        vm.expectRevert(bytes("deposit too low"));
        consumer.open{value: q - 1}(1, "x");
    }

    function test_openCase_creditsExcessRefund() public {
        uint256 q = court.quoteOpen();
        uint256 before = address(consumer).balance;
        consumer.open{value: q + 1 ether}(42, "buyer never shipped");
        assertEq(address(consumer).balance, before);
        assertEq(court.pendingRefunds(address(consumer)), 1 ether);

        consumer.withdrawCourtRefund();
        assertEq(address(consumer).balance, before + 1 ether);
        assertEq(court.pendingRefunds(address(consumer)), 0);
    }

    function test_sweep_preservesPendingRefunds() public {
        uint256 q = court.quoteOpen();
        consumer.open{value: q + 1 ether}(42, "buyer never shipped");
        (bool ok,) = payable(address(court)).call{value: 2 ether}("");
        require(ok, "fund court");

        court.sweep(address(this));
        assertEq(court.pendingRefunds(address(consumer)), 1 ether);
        assertEq(address(court).balance, 1 ether);

        consumer.withdrawCourtRefund();
        assertEq(address(court).balance, 0);
    }

    function test_quoteAppeal_revertsUnknownCase() public {
        vm.expectRevert(bytes("unknown case"));
        court.quoteAppeal(999);
    }

    function test_quoteAppeal_revertsAfterMaxRound() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(1, "r0");
        platform.fireSuccess(_lastReq(), "PAYER");
        consumer.doAppeal{value: court.quoteAppeal(caseId)}(caseId, "r1");
        platform.fireSuccess(_lastReq(), "PAYER");

        vm.expectRevert(bytes("no rounds left"));
        court.quoteAppeal(caseId);
    }

    function test_verdictReached_andFinalize() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(7, "evidence");
        platform.fireSuccess(_lastReq(), "PAYEE");

        CaseView memory cv = court.getCase(caseId);
        assertEq(uint8(cv.status), uint8(CaseStatus.Ruled));
        assertEq(uint8(cv.verdict), uint8(Verdict.PAYEE));
        assertGt(cv.receiptId, 0);

        vm.expectRevert(bytes("appeal window open"));
        court.finalize(caseId);

        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Final));
        assertEq(uint8(consumer.lastVerdict()), uint8(Verdict.PAYEE));
        assertEq(consumer.lastRef(), 7);
    }

    function test_appeal_escalatesPanel_thenFinalizes() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(1, "round0");
        platform.fireSuccess(_lastReq(), "PAYER");

        consumer.doAppeal{value: court.quoteAppeal(caseId)}(caseId, "round1 new evidence");
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Pending));
        assertEq(court.getCase(caseId).round, 1);

        platform.fireSuccess(_lastReq(), "PAYEE");
        court.finalize(caseId); // final round: no window wait
        assertEq(uint8(consumer.lastVerdict()), uint8(Verdict.PAYEE));
    }

    function test_appeal_revertsAfterMaxRound() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(1, "r0");
        platform.fireSuccess(_lastReq(), "PAYER");
        consumer.doAppeal{value: court.quoteAppeal(caseId)}(caseId, "r1");
        platform.fireSuccess(_lastReq(), "PAYER");
        vm.expectRevert(bytes("no rounds left"));
        consumer.doAppeal{value: 1 ether}(caseId, "r2");
    }

    function test_appeal_revertsAfterWindow() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(1, "r0");
        platform.fireSuccess(_lastReq(), "PAYER");
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 dep = court.quoteAppeal(caseId);
        vm.expectRevert(bytes("window closed"));
        consumer.doAppeal{value: dep}(caseId, "late");
    }

    function test_appealDeadline_isSnapshottedAtRulingTime() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(1, "r0");
        platform.fireSuccess(_lastReq(), "PAYER");

        court.setAppealWindow(1);
        vm.warp(block.timestamp + 2);

        vm.expectRevert(bytes("appeal window open"));
        court.finalize(caseId);

        consumer.doAppeal{value: court.quoteAppeal(caseId)}(caseId, "new evidence");
        assertEq(court.getCase(caseId).round, 1);
    }

    function test_handleVerdict_onlyPlatform() public {
        consumer.open{value: court.quoteOpen()}(1, "x");
        uint256 rid = _lastReq();
        Response[] memory empty = new Response[](0);
        Request memory r;
        vm.expectRevert(bytes("only platform"));
        court.handleVerdict(rid, empty, ResponseStatus.Success, r);
    }

    function test_erroredOnFailure_thenRetry() public {
        uint256 caseId = consumer.open{value: court.quoteOpen()}(1, "x");
        platform.fireStatus(_lastReq(), ResponseStatus.Failed);
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Errored));

        consumer.doRetry{value: court.quoteOpen()}(caseId);
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Pending));
        platform.fireSuccess(_lastReq(), "SPLIT");
        assertEq(uint8(court.getCase(caseId).verdict), uint8(Verdict.SPLIT));
    }
}
