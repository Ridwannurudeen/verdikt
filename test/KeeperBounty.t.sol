// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {VerdiktKeeperBounty} from "../src/VerdiktKeeperBounty.sol";
import {CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Incentivized, permissionless settlement: fund a bounty to finalize a case; any keeper
/// claims it by settling the case (or just claims if someone already did).
contract KeeperBountyTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;
    VerdiktKeeperBounty bounty;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address funder = makeAddr("funder");
    address keeper = makeAddr("keeper");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), makeAddr("treasury"));
        bounty = new VerdiktKeeperBounty();
        vm.deal(payer, 100 ether);
        vm.deal(funder, 100 ether);
    }

    /// Create a disputed, ruled case and return its caseId (appeal window NOT yet warped).
    function _ruledCase() internal returns (uint256 caseId) {
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(payee, uint64(block.timestamp + 1 days));
        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "evidence");
        platform.fireSuccess(platform.nextId() - 1, "PAYER");
        (,,,,, caseId) = escrow.deals(dealId);
    }

    function test_fund_and_reclaim() public {
        uint256 caseId = _ruledCase();
        vm.prank(funder);
        bounty.fundBounty{value: 0.5 ether}(address(court), caseId);
        assertEq(bounty.pot(bounty.key(address(court), caseId)), 0.5 ether);

        uint256 before = funder.balance;
        vm.prank(funder);
        bounty.reclaim(address(court), caseId);
        assertEq(funder.balance, before + 0.5 ether);
        assertEq(bounty.pot(bounty.key(address(court), caseId)), 0);
    }

    function test_finalizeAndClaim_paysKeeper_andSettles() public {
        uint256 caseId = _ruledCase();
        vm.prank(funder);
        bounty.fundBounty{value: 0.5 ether}(address(court), caseId);

        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 before = keeper.balance;
        vm.prank(keeper);
        bounty.finalizeAndClaim(address(court), caseId);

        assertEq(keeper.balance, before + 0.5 ether, "keeper paid the bounty");
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Final), "case finalized");
        assertTrue(bounty.claimed(bounty.key(address(court), caseId)));
    }

    function test_finalizeAndClaim_whenAlreadyFinal_stillPays() public {
        uint256 caseId = _ruledCase();
        vm.prank(funder);
        bounty.fundBounty{value: 0.3 ether}(address(court), caseId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId); // someone else finalizes first

        uint256 before = keeper.balance;
        vm.prank(keeper);
        bounty.finalizeAndClaim(address(court), caseId);
        assertEq(keeper.balance, before + 0.3 ether);
    }

    function test_finalizeAndClaim_beforeWindow_reverts() public {
        uint256 caseId = _ruledCase();
        vm.prank(funder);
        bounty.fundBounty{value: 0.3 ether}(address(court), caseId);
        vm.prank(keeper);
        vm.expectRevert(bytes("appeal window open"));
        bounty.finalizeAndClaim(address(court), caseId);
    }

    function test_doubleClaim_reverts() public {
        uint256 caseId = _ruledCase();
        vm.prank(funder);
        bounty.fundBounty{value: 0.3 ether}(address(court), caseId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        vm.prank(keeper);
        bounty.finalizeAndClaim(address(court), caseId);
        vm.prank(keeper);
        vm.expectRevert(bytes("no bounty"));
        bounty.finalizeAndClaim(address(court), caseId);
    }
}
