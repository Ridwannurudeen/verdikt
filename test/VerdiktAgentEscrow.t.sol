// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktAgentEscrow} from "../src/VerdiktAgentEscrow.sol";
import {IVerdiktCourt, Verdict, CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice An agent contract that can hold a deal balance but reverts on ETH receipt
/// (no payable receive/fallback). Used to prove a broken counterparty can't brick settlement.
contract NonReceivingAgent {
    function tryWithdraw(VerdiktAgentEscrow e) external returns (uint256) {
        return e.withdraw();
    }
}

contract VerdiktAgentEscrowTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktAgentEscrow escrow;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktAgentEscrow(address(court), treasury);
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

    /// @dev Withdraw `who`'s pending balance and assert it equals `expected`.
    function _assertWithdraw(address who, uint256 expected) internal {
        assertEq(escrow.pending(who), expected, "pending mismatch");
        uint256 before = who.balance;
        vm.prank(who);
        escrow.withdraw();
        assertEq(who.balance, before + expected, "withdraw mismatch");
    }

    function test_release_byPayer() public {
        uint256 dealId = _newDeal();
        vm.prank(payee);
        escrow.markDelivered(dealId);
        vm.prank(payer);
        escrow.release(dealId);
        _assertWithdraw(payee, 1 ether);
    }

    function test_autoRelease_afterDeadline() public {
        uint256 dealId = _newDeal();
        vm.prank(payee);
        escrow.markDelivered(dealId);
        vm.warp(block.timestamp + 2 days);
        escrow.release(dealId); // anyone can poke after deadline
        _assertWithdraw(payee, 1 ether);
    }

    function test_dispute_payeeWins() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "goods delivered as agreed");
        platform.fireSuccess(_lastReq(), "PAYEE");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        _assertWithdraw(payee, 1 ether);
        (,,, VerdiktAgentEscrow.DealStatus st,,) = escrow.deals(dealId);
        assertEq(uint8(st), uint8(VerdiktAgentEscrow.DealStatus.Settled));
    }

    function test_dispute_payerWins() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payee, "never received anything");
        platform.fireSuccess(_lastReq(), "PAYER");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        _assertWithdraw(payer, 1 ether);
    }

    function test_dispute_split() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "partially delivered");
        platform.fireSuccess(_lastReq(), "SPLIT");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        assertEq(escrow.pending(payer), 0.5 ether);
        assertEq(escrow.pending(payee), 0.5 ether);
    }

    function test_dispute_gradedSplit75() public {
        court.setGradedSplit(true);
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "mostly delivered");
        platform.fireSuccess(_lastReq(), "SPLIT75");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        assertEq(escrow.pending(payer), 0.25 ether);
        assertEq(escrow.pending(payee), 0.75 ether);
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

        court.finalize(caseId); // round 1 == MAX_ROUND, finalize immediately
        // payee: 1 ether deal + 0.095 slashed stake; treasury: 0.005 cut
        assertEq(escrow.pending(payee), 1 ether + 0.095 ether);
        assertEq(escrow.pending(treasury), 0.005 ether);
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

        court.finalize(caseId);
        // payer: 1 ether deal (PAYER) + 0.1 returned stake
        assertEq(escrow.pending(payer), 1.1 ether);
    }

    /// @notice The agent-native property: a payee that reverts on ETH receipt cannot brick the
    /// court callback or strand the payer's share. Push-payment settlement would revert in
    /// onVerdict (and thus in finalize); pull-payment credits both sides and lets the payer exit.
    function test_settles_toNonReceivingAgent_doesNotBrick() public {
        NonReceivingAgent agent = new NonReceivingAgent();
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(address(agent), uint64(block.timestamp + 1 days));

        _dispute(dealId, payer, "agent never delivered");
        platform.fireSuccess(_lastReq(), "SPLIT");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId); // must NOT revert despite the broken counterparty

        assertEq(escrow.pending(payer), 0.5 ether);
        assertEq(escrow.pending(address(agent)), 0.5 ether);

        // honest payer exits cleanly...
        _assertWithdraw(payer, 0.5 ether);
        // ...while the broken agent only blocks its own withdrawal.
        vm.expectRevert(bytes("withdraw failed"));
        agent.tryWithdraw(escrow);
    }

    function test_withdraw_revertsWhenEmpty() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("nothing to withdraw"));
        escrow.withdraw();
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
