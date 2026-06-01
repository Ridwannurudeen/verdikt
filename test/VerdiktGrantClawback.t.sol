// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktGrantClawback} from "../src/VerdiktGrantClawback.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktGrantClawbackTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktGrantClawback grant;

    address dao = makeAddr("dao"); // funder
    address grantee = makeAddr("grantee");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        grant = new VerdiktGrantClawback(address(court), treasury);
        vm.deal(dao, 100 ether);
        vm.deal(grantee, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 grantId) internal view returns (uint256 c) {
        (,,,,, c) = grant.grants(grantId);
    }

    function _status(uint256 grantId) internal view returns (VerdiktGrantClawback.GrantStatus st) {
        (,,, st,,) = grant.grants(grantId);
    }

    function _newGrant() internal returns (uint256 grantId) {
        vm.prank(dao);
        grantId = grant.createGrant{value: 1 ether}(grantee, uint64(block.timestamp + 30 days));
    }

    function _dispute(uint256 grantId, address who, string memory ev) internal {
        uint256 fee = court.quoteOpen();
        vm.prank(who);
        grant.dispute{value: fee}(grantId, ev);
    }

    function _finalize(uint256 grantId) internal {
        uint256 caseId = _caseId(grantId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
    }

    function test_clawback_payerRefundsDAO() public {
        uint256 grantId = _newGrant();
        _dispute(grantId, dao, "grantee missed the milestone");
        platform.fireSuccess(_lastReq(), "PAYER");
        _finalize(grantId);

        // PAYER = clawback to the DAO funder.
        assertEq(grant.pending(dao), 1 ether);
        assertEq(grant.pending(grantee), 0);
        assertEq(uint8(_status(grantId)), uint8(VerdiktGrantClawback.GrantStatus.Settled));

        uint256 before = dao.balance;
        vm.prank(dao);
        grant.withdraw();
        assertEq(dao.balance, before + 1 ether);
        assertEq(grant.pending(dao), 0);
    }

    function test_release_payeeToGrantee() public {
        uint256 grantId = _newGrant();
        _dispute(grantId, grantee, "milestone delivered in full");
        platform.fireSuccess(_lastReq(), "PAYEE");
        _finalize(grantId);

        assertEq(grant.pending(grantee), 1 ether);
        assertEq(grant.pending(dao), 0);

        uint256 before = grantee.balance;
        vm.prank(grantee);
        grant.withdraw();
        assertEq(grantee.balance, before + 1 ether);
    }

    function test_split_halfEach() public {
        uint256 grantId = _newGrant();
        _dispute(grantId, dao, "partially delivered");
        platform.fireSuccess(_lastReq(), "SPLIT");
        _finalize(grantId);

        assertEq(grant.pending(dao), 0.5 ether);
        assertEq(grant.pending(grantee), 0.5 ether);

        uint256 daoBefore = dao.balance;
        uint256 granteeBefore = grantee.balance;
        vm.prank(dao);
        grant.withdraw();
        vm.prank(grantee);
        grant.withdraw();
        assertEq(dao.balance, daoBefore + 0.5 ether);
        assertEq(grantee.balance, granteeBefore + 0.5 ether);
    }

    function test_gradedSplit75_releasesThreeQuarters() public {
        court.setGradedSplit(true);
        uint256 grantId = _newGrant();
        _dispute(grantId, dao, "mostly delivered");
        platform.fireSuccess(_lastReq(), "SPLIT75");
        _finalize(grantId);

        assertEq(grant.pending(dao), 0.25 ether);
        assertEq(grant.pending(grantee), 0.75 ether);
    }

    function test_dispute_onlyParty() public {
        uint256 grantId = _newGrant();
        uint256 fee = court.quoteOpen();
        vm.prank(stranger);
        vm.expectRevert(bytes("not a party"));
        grant.dispute{value: fee}(grantId, "x");
    }

    function test_onVerdict_onlyCourt() public {
        uint256 grantId = _newGrant();
        vm.expectRevert(bytes("only court"));
        grant.onVerdict(grantId, Verdict.PAYER);
    }

    function test_withdraw_nothing() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("nothing to withdraw"));
        grant.withdraw();
    }

    function test_dispute_refundsExcess() public {
        uint256 grantId = _newGrant();
        uint256 fee = court.quoteOpen();
        uint256 before = dao.balance;
        vm.prank(dao);
        grant.dispute{value: fee + 1 ether}(grantId, "ev");
        assertEq(dao.balance, before - fee - 1 ether);
        assertEq(grant.pending(dao), 1 ether);

        vm.prank(dao);
        grant.withdraw();
        assertEq(dao.balance, before - fee);
    }
}
