// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktMarketplace} from "../src/VerdiktMarketplace.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice The staked arbitration marketplace: back a court with a bond, challenge bad rulings,
/// governance slashes/rewards, and routing is quality-weighted.
contract MarketplaceTest is Test {
    MockAgentRequester platform;
    VerdiktCourt courtA;
    VerdiktCourt courtB;
    VerdiktMarketplace mkt;

    address gov = address(this); // marketplace owner
    address treasury = makeAddr("treasury");
    address opA = makeAddr("opA");
    address opB = makeAddr("opB");
    address challenger = makeAddr("challenger");

    function setUp() public {
        platform = new MockAgentRequester();
        courtA = new VerdiktCourt(address(platform), 1);
        courtB = new VerdiktCourt(address(platform), 1);
        mkt = new VerdiktMarketplace(treasury);
        vm.deal(opA, 100 ether);
        vm.deal(opB, 100 ether);
        vm.deal(challenger, 100 ether);
    }

    function _back(address op, VerdiktCourt court, uint256 stake) internal {
        vm.prank(op);
        mkt.backCourt{value: stake}(address(court), "Court");
    }

    // --- backing --------------------------------------------------------------

    function test_back_requiresMinStakeAndValidCourt() public {
        vm.prank(opA);
        vm.expectRevert(bytes("stake too low"));
        mkt.backCourt{value: 0.5 ether}(address(courtA), "A");

        _back(opA, courtA, 1 ether);
        (address operator, uint256 stake,, bool active,,,) = mkt.backing(address(courtA));
        assertEq(operator, opA);
        assertEq(stake, 1 ether);
        assertTrue(active);

        vm.prank(opB);
        vm.expectRevert(bytes("already backed"));
        mkt.backCourt{value: 1 ether}(address(courtA), "dup");
    }

    function test_addStake_onlyOperator() public {
        _back(opA, courtA, 1 ether);
        vm.prank(opB);
        vm.expectRevert(bytes("not operator"));
        mkt.addStake{value: 1 ether}(address(courtA));
        vm.prank(opA);
        mkt.addStake{value: 1 ether}(address(courtA));
        (, uint256 stake,,,,,) = mkt.backing(address(courtA));
        assertEq(stake, 2 ether);
    }

    // --- challenge / slash ----------------------------------------------------

    function test_challenge_upheld_slashesToChallengerAndTreasury() public {
        _back(opA, courtA, 1 ether);
        vm.prank(challenger);
        mkt.challenge{value: 0.2 ether}(address(courtA), 1);

        mkt.resolveChallenge(address(courtA), true); // gov upholds -> slash 20% = 0.2 ether

        (, uint256 stake,,,, uint64 upheld,) = mkt.backing(address(courtA));
        assertEq(stake, 0.8 ether, "stake slashed 20%");
        assertEq(upheld, 1);
        // challenger: bond 0.2 back + reward 0.1 = 0.3; treasury: 0.1
        assertEq(mkt.pending(challenger), 0.3 ether);
        assertEq(mkt.pending(treasury), 0.1 ether);
    }

    function test_challenge_rejected_paysOperator() public {
        _back(opA, courtA, 1 ether);
        vm.prank(challenger);
        mkt.challenge{value: 0.2 ether}(address(courtA), 1);

        mkt.resolveChallenge(address(courtA), false); // frivolous

        (, uint256 stake,,,,, uint64 rejected) = mkt.backing(address(courtA));
        assertEq(stake, 1 ether, "no slash");
        assertEq(rejected, 1);
        assertEq(mkt.pending(opA), 0.2 ether, "operator keeps the bond");
    }

    function test_resolve_onlyOwner_and_oneChallengeAtATime() public {
        _back(opA, courtA, 1 ether);
        vm.prank(challenger);
        mkt.challenge{value: 0.2 ether}(address(courtA), 1);

        vm.prank(challenger);
        vm.expectRevert(bytes("challenge pending"));
        mkt.challenge{value: 0.2 ether}(address(courtA), 2);

        vm.prank(opB);
        vm.expectRevert(bytes("not owner"));
        mkt.resolveChallenge(address(courtA), true);
    }

    // --- unbonding ------------------------------------------------------------

    function test_unbond_withdrawAfterDelay_blockedByChallenge() public {
        _back(opA, courtA, 1 ether);
        vm.prank(opA);
        mkt.beginUnbond(address(courtA));

        vm.prank(opA);
        vm.expectRevert(bytes("still bonded"));
        mkt.withdrawStake(address(courtA));

        vm.warp(block.timestamp + 7 days + 1);
        // an open challenge blocks withdrawal
        vm.prank(challenger);
        mkt.challenge{value: 0.2 ether}(address(courtA), 1);
        vm.prank(opA);
        vm.expectRevert(bytes("challenge open"));
        mkt.withdrawStake(address(courtA));

        mkt.resolveChallenge(address(courtA), false);
        vm.prank(opA);
        mkt.withdrawStake(address(courtA));
        assertEq(mkt.pending(opA), 1 ether + 0.2 ether); // stake back + frivolous bond
    }

    // --- routing --------------------------------------------------------------

    function test_bestCourt_routesByQuality() public {
        _back(opA, courtA, 1 ether);
        _back(opB, courtB, 1 ether);

        // both clean -> tie on score(0) and fee, broken by larger stake; bump B's stake
        vm.prank(opB);
        mkt.addStake{value: 1 ether}(address(courtB));
        (address best,) = mkt.bestCourt();
        assertEq(best, address(courtB), "larger stake wins a clean tie");

        // now A takes an upheld challenge -> score -3 -> B (score 0) wins regardless
        vm.prank(challenger);
        mkt.challenge{value: 0.2 ether}(address(courtA), 1);
        mkt.resolveChallenge(address(courtA), true);
        assertLt(mkt.score(address(courtA)), mkt.score(address(courtB)));
        (best,) = mkt.bestCourt();
        assertEq(best, address(courtB), "clean court wins routing");
    }

    function test_withdraw_pullPayment() public {
        _back(opA, courtA, 1 ether);
        vm.prank(challenger);
        mkt.challenge{value: 0.2 ether}(address(courtA), 1);
        mkt.resolveChallenge(address(courtA), false);
        uint256 before = opA.balance;
        vm.prank(opA);
        mkt.withdraw();
        assertEq(opA.balance, before + 0.2 ether);
        assertEq(mkt.pending(opA), 0);
    }

    function test_admin_access() public {
        vm.prank(opA);
        vm.expectRevert(bytes("not owner"));
        mkt.setParams(2 ether, 0.5 ether, 1000, 1 days);
        mkt.setParams(2 ether, 0.5 ether, 1000, 1 days);
        assertEq(mkt.minStake(), 2 ether);
    }
}
