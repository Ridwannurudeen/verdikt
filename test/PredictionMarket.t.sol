// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktPredictionMarket} from "../src/examples/VerdiktPredictionMarket.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Judgment-as-an-oracle: a binary prediction market resolved by the AI jury. PAYEE = YES,
/// PAYER = NO, SPLIT/UNDECIDABLE = VOID. Winners split the whole pool pro-rata; a void refunds stakes.
contract PredictionMarketTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktPredictionMarket mkt;

    address alice = makeAddr("alice"); // YES 0.3
    address bob = makeAddr("bob"); // YES 0.1
    address carol = makeAddr("carol"); // NO 0.6

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        mkt = new VerdiktPredictionMarket(address(court));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function _market() internal returns (uint256 id) {
        id = mkt.createMarket("Did the team ship the feature by the deadline?", uint64(block.timestamp + 1 days));
        vm.prank(alice);
        mkt.stakeYes{value: 0.3 ether}(id);
        vm.prank(bob);
        mkt.stakeYes{value: 0.1 ether}(id);
        vm.prank(carol);
        mkt.stakeNo{value: 0.6 ether}(id);
    }

    function _resolveWith(uint256 id, string memory label) internal {
        vm.warp(block.timestamp + 1 days + 1);
        uint256 fee = court.quoteOpen();
        vm.deal(address(this), fee);
        mkt.resolve{value: fee}(id, "evidence");
        platform.fireSuccess(platform.nextId() - 1, label);
        uint256 caseId = mkt.refToCase(id);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    function test_yesWins_winnersSplitPoolProRata() public {
        uint256 id = _market();
        _resolveWith(id, "PAYEE"); // YES wins
        // total pool 1.0; alice 0.3/0.4 -> 0.75, bob 0.1/0.4 -> 0.25
        vm.prank(alice);
        mkt.claim(id);
        vm.prank(bob);
        mkt.claim(id);
        assertEq(mkt.pending(alice), 0.75 ether);
        assertEq(mkt.pending(bob), 0.25 ether);
        // a losing (NO) staker cannot claim
        vm.prank(carol);
        vm.expectRevert(bytes("no winning stake"));
        mkt.claim(id);
    }

    function test_noWins() public {
        uint256 id = _market();
        _resolveWith(id, "PAYER"); // NO wins
        vm.prank(carol);
        mkt.claim(id);
        assertEq(mkt.pending(carol), 1 ether); // sole NO staker takes the whole pool
        vm.prank(alice);
        vm.expectRevert(bytes("no winning stake"));
        mkt.claim(id);
    }

    function test_split_voidsAndRefunds() public {
        uint256 id = _market();
        _resolveWith(id, "SPLIT"); // VOID
        vm.prank(alice);
        mkt.claim(id);
        vm.prank(carol);
        mkt.claim(id);
        assertEq(mkt.pending(alice), 0.3 ether); // own stake back
        assertEq(mkt.pending(carol), 0.6 ether);
    }

    function test_undecidable_voids() public {
        uint256 id = _market();
        _resolveWith(id, "UNDECIDABLE");
        (,,,,, VerdiktPredictionMarket.Outcome outcome) = mkt.markets(id);
        assertEq(uint8(outcome), uint8(VerdiktPredictionMarket.Outcome.Void));
    }

    function test_withdraw_pullPayment() public {
        uint256 id = _market();
        _resolveWith(id, "PAYEE");
        vm.prank(alice);
        mkt.claim(id);
        uint256 before = alice.balance;
        vm.prank(alice);
        mkt.withdraw();
        assertEq(alice.balance, before + 0.75 ether);
    }

    function test_guards() public {
        uint256 id = mkt.createMarket("q", uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("staking closed"));
        mkt.stakeYes{value: 1 ether}(id);
        vm.prank(alice);
        vm.expectRevert(bytes("unresolved"));
        mkt.claim(id);
    }
}
