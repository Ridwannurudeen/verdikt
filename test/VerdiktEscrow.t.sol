// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {IVerdiktCourt, Verdict, CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktEscrowTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        vm.deal(payer, 100 ether);
        vm.deal(payee, 100 ether);
        vm.deal(stranger, 100 ether);
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
        uint256 fee = court.quoteOpen(); // cache before prank (a call here would consume the prank)
        vm.prank(who);
        escrow.dispute{value: fee}(dealId, ev);
    }

    function test_release_byPayer() public {
        uint256 dealId = _newDeal();
        vm.prank(payee);
        escrow.markDelivered(dealId);
        uint256 before = payee.balance;
        vm.prank(payer);
        escrow.release(dealId);
        assertEq(payee.balance, before + 1 ether);
    }

    function test_autoRelease_afterDeadline() public {
        uint256 dealId = _newDeal();
        vm.prank(payee);
        escrow.markDelivered(dealId);
        vm.warp(block.timestamp + 2 days);
        uint256 before = payee.balance;
        escrow.release(dealId); // anyone can poke after deadline
        assertEq(payee.balance, before + 1 ether);
    }

    function test_dispute_payeeWins() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "goods delivered as agreed");
        platform.fireSuccess(_lastReq(), "PAYEE");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 before = payee.balance;
        court.finalize(caseId);
        assertEq(payee.balance, before + 1 ether);
        (,,, VerdiktEscrow.DealStatus st,,) = escrow.deals(dealId);
        assertEq(uint8(st), uint8(VerdiktEscrow.DealStatus.Settled));
    }

    function test_dispute_payerWins() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payee, "never received anything");
        platform.fireSuccess(_lastReq(), "PAYER");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 before = payer.balance;
        court.finalize(caseId);
        assertEq(payer.balance, before + 1 ether);
    }

    function test_dispute_split() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "partially delivered");
        platform.fireSuccess(_lastReq(), "SPLIT");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 pBefore = payer.balance;
        uint256 eBefore = payee.balance;
        court.finalize(caseId);
        assertEq(payer.balance, pBefore + 0.5 ether);
        assertEq(payee.balance, eBefore + 0.5 ether);
    }

    function test_appeal_upheld_slashesStake() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // payer loses round 0

        uint256 caseId = _caseId(dealId);
        uint256 stake = 0.1 ether; // 10% of 1 ether
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(payer);
        escrow.appeal{value: stake + agentDep}(dealId, "new evidence");
        platform.fireSuccess(_lastReq(), "PAYEE"); // upheld on appeal

        uint256 payeeBefore = payee.balance;
        uint256 treasBefore = treasury.balance;
        court.finalize(caseId); // round 1 == MAX_ROUND, finalize immediately
        assertEq(payee.balance, payeeBefore + 1 ether + 0.095 ether);
        assertEq(treasury.balance, treasBefore + 0.005 ether);
    }

    function test_appeal_overturned_returnsStake() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // payer loses round 0

        uint256 caseId = _caseId(dealId);
        uint256 stake = 0.1 ether;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(payer);
        escrow.appeal{value: stake + agentDep}(dealId, "compelling new evidence");
        platform.fireSuccess(_lastReq(), "PAYER"); // overturned

        uint256 before = payer.balance;
        court.finalize(caseId);
        assertEq(payer.balance, before + 1.1 ether);
    }

    function test_dispute_onlyParty() public {
        uint256 dealId = _newDeal();
        uint256 fee = court.quoteOpen();
        vm.prank(stranger);
        vm.expectRevert(bytes("not a party"));
        escrow.dispute{value: fee}(dealId, "x");
    }

    function test_onVerdict_onlyCourt() public {
        uint256 dealId = _newDeal();
        vm.expectRevert(bytes("only court"));
        escrow.onVerdict(dealId, Verdict.PAYEE);
    }

    function test_appeal_onlyLoser() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // payer loses; payee is winner

        uint256 caseId = _caseId(dealId);
        uint256 agentDep = court.quoteAppeal(caseId);
        uint256 value = 0.1 ether + agentDep;
        vm.prank(payee); // winner cannot appeal
        vm.expectRevert(bytes("only losing party"));
        escrow.appeal{value: value}(dealId, "x");
    }
}
