// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {SimpleEscrow} from "../src/examples/SimpleEscrow.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Exercises the SDK: VerdiktConsumerBase + the SimpleEscrow reference integration end-to-end,
/// proving a few-line consumer settles PAYEE/PAYER/graded-SPLIT/UNDECIDABLE correctly for free.
contract SimpleEscrowTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    SimpleEscrow escrow;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new SimpleEscrow(address(court));
        vm.deal(payer, 100 ether);
    }

    function _disputeAndRule(string memory label) internal returns (uint256 id, uint256 caseId) {
        vm.prank(payer);
        id = escrow.createDeal{value: 1 ether}(payee);
        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(id, "evidence");
        platform.fireSuccess(platform.nextId() - 1, label);
        caseId = escrow.refToCase(id);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    function test_payee_getsAll() public {
        _disputeAndRule("PAYEE");
        assertEq(escrow.pending(payee), 1 ether);
        assertEq(escrow.pending(payer), 0);
    }

    function test_payer_getsAll() public {
        _disputeAndRule("PAYER");
        assertEq(escrow.pending(payer), 1 ether);
        assertEq(escrow.pending(payee), 0);
    }

    function test_gradedSplit_honored() public {
        court.setGradedSplit(true);
        _disputeAndRule("SPLIT75");
        assertEq(escrow.pending(payee), 0.75 ether);
        assertEq(escrow.pending(payer), 0.25 ether);
    }

    function test_undecidable_refundsPayer() public {
        _disputeAndRule("UNDECIDABLE");
        assertEq(escrow.pending(payer), 1 ether);
        assertEq(escrow.pending(payee), 0);
    }

    function test_onlyCourt_guardsCallback() public {
        vm.expectRevert(bytes("only court"));
        escrow.onVerdict(1, Verdict.PAYEE);
    }

    function test_dispute_refundsExcessFee() public {
        vm.prank(payer);
        uint256 id = escrow.createDeal{value: 1 ether}(payee);
        uint256 fee = court.quoteOpen();
        uint256 before = payer.balance;
        vm.prank(payer);
        escrow.dispute{value: fee + 0.5 ether}(id, "evidence");
        assertEq(payer.balance, before - fee - 0.5 ether);
        assertEq(escrow.pendingRefunds(payer), 0.5 ether);

        vm.prank(payer);
        escrow.withdrawRefund();
        assertEq(payer.balance, before - fee);
        assertEq(escrow.pendingRefunds(payer), 0);
    }

    function test_dispute_excessRefundCannotBrickNonReceiver() public {
        RefundRejecter rejecter = new RefundRejecter(escrow, payee);
        vm.deal(address(rejecter), 100 ether);
        uint256 fee = court.quoteOpen();
        uint256 id = rejecter.create();

        rejecter.dispute(id, fee + 0.5 ether);

        assertEq(escrow.pendingRefunds(address(rejecter)), 0.5 ether);
    }
}

contract RefundRejecter {
    SimpleEscrow immutable escrow;
    address immutable payee;

    constructor(SimpleEscrow escrow_, address payee_) {
        escrow = escrow_;
        payee = payee_;
    }

    function create() external returns (uint256) {
        return escrow.createDeal{value: 1 ether}(payee);
    }

    function dispute(uint256 id, uint256 value) external {
        escrow.dispute{value: value}(id, "evidence");
    }

    receive() external payable {
        revert("reject");
    }
}
