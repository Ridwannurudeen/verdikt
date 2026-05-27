// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktInsurance} from "../src/VerdiktInsurance.sol";
import {IVerdiktCourt, Verdict, CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktInsuranceTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktInsurance ins;

    address funder = makeAddr("funder");
    address funder2 = makeAddr("funder2");
    address insured = makeAddr("insured");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    uint256 constant COVERAGE = 1 ether;

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        ins = new VerdiktInsurance(address(court), treasury);
        vm.deal(funder, 100 ether);
        vm.deal(funder2, 100 ether);
        vm.deal(insured, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 claimId) internal view returns (uint256 c) {
        (,, c) = ins.claims(claimId);
    }

    function _fund(address from, uint256 amount) internal {
        vm.prank(from);
        ins.fundPool{value: amount}();
    }

    function _policy() internal returns (uint256 policyId) {
        uint256 premium = (COVERAGE * ins.premiumBps()) / 10000;
        vm.prank(insured);
        policyId = ins.createPolicy{value: premium}(COVERAGE, uint64(block.timestamp + 30 days));
    }

    function _fileClaim(uint256 policyId, string memory ev) internal returns (uint256 claimId) {
        uint256 fee = court.quoteOpen();
        vm.prank(insured);
        claimId = ins.fileClaim{value: fee}(policyId, ev);
    }

    // -------------------------------------------------------------------------

    function test_fundPool_recordsShare() public {
        _fund(funder, 5 ether);
        assertEq(ins.shares(funder), 5 ether);
        assertEq(ins.totalShares(), 5 ether);
        assertEq(ins.totalPool(), 5 ether);
    }

    function test_createPolicy_paysPremium_intoPool() public {
        _fund(funder, 10 ether);
        uint256 poolBefore = ins.totalPool();
        uint256 policyId = _policy();
        uint256 premium = (COVERAGE * ins.premiumBps()) / 10000; // 0.05 ether
        assertEq(ins.totalPool(), poolBefore + premium);
        (address ins_, uint256 cov, uint64 exp, VerdiktInsurance.PolicyStatus st, uint256 active) =
            ins.policies(policyId);
        assertEq(ins_, insured);
        assertEq(cov, COVERAGE);
        assertGt(exp, block.timestamp);
        assertEq(uint8(st), uint8(VerdiktInsurance.PolicyStatus.Active));
        assertEq(active, 0);
    }

    function test_fileClaim_byNonInsured_reverts() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 fee = court.quoteOpen();
        vm.prank(stranger);
        vm.expectRevert(bytes("only insured"));
        ins.fileClaim{value: fee}(policyId, "x");
    }

    function test_fileClaim_payeeWins_paysCoverage() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "house burned down, photos attached");
        platform.fireSuccess(_lastReq(), "PAYEE");

        uint256 caseId = _caseId(claimId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 before = insured.balance;
        court.finalize(caseId);

        assertEq(insured.balance, before + COVERAGE);
        (,,, VerdiktInsurance.PolicyStatus st, uint256 active) = ins.policies(policyId);
        assertEq(uint8(st), uint8(VerdiktInsurance.PolicyStatus.Exhausted));
        assertEq(active, 0);
    }

    function test_fileClaim_payerWins_noPayout() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "fraudulent claim attempt");
        platform.fireSuccess(_lastReq(), "PAYER");

        uint256 caseId = _caseId(claimId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 before = insured.balance;
        court.finalize(caseId);

        assertEq(insured.balance, before); // no payout
        (,,, VerdiktInsurance.PolicyStatus st,) = ins.policies(policyId);
        // policy still active (not expired)
        assertEq(uint8(st), uint8(VerdiktInsurance.PolicyStatus.Active));
    }

    function test_fileClaim_split_paysHalf() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "partial loss");
        platform.fireSuccess(_lastReq(), "SPLIT");

        uint256 caseId = _caseId(claimId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 before = insured.balance;
        court.finalize(caseId);

        assertEq(insured.balance, before + COVERAGE / 2);
        (,,, VerdiktInsurance.PolicyStatus st,) = ins.policies(policyId);
        assertEq(uint8(st), uint8(VerdiktInsurance.PolicyStatus.Exhausted));
    }

    function test_appeal_byInsured_overturned_returnsStake() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "ev0");
        platform.fireSuccess(_lastReq(), "PAYER"); // insured loses round 0

        uint256 caseId = _caseId(claimId);
        uint256 stake = (COVERAGE * ins.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(insured);
        ins.appealClaim{value: stake + agentDep}(claimId, "compelling new evidence");
        platform.fireSuccess(_lastReq(), "PAYEE"); // overturned

        uint256 before = insured.balance;
        court.finalize(caseId);
        // insured gets coverage payout + stake returned
        assertEq(insured.balance, before + COVERAGE + stake);
    }

    function test_appeal_byInsured_upheld_slashesStake_treasuryCut() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "ev0");
        platform.fireSuccess(_lastReq(), "PAYER"); // insured loses round 0

        uint256 caseId = _caseId(claimId);
        uint256 stake = (COVERAGE * ins.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(insured);
        ins.appealClaim{value: stake + agentDep}(claimId, "weak appeal");
        platform.fireSuccess(_lastReq(), "PAYER"); // upheld

        uint256 cut = (stake * ins.keeperCutBps()) / 10000;
        uint256 toWinner = stake - cut;
        uint256 poolBefore = ins.totalPool();
        uint256 trBefore = treasury.balance;
        court.finalize(caseId);

        assertEq(treasury.balance, trBefore + cut);
        // pool wins the stake (minus treasury cut)
        assertEq(ins.totalPool(), poolBefore + toWinner);
    }

    function test_appeal_byPoolFunder_overturned_returnsStake() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // pool loses round 0

        uint256 caseId = _caseId(claimId);
        uint256 stake = (COVERAGE * ins.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(funder);
        ins.appealClaim{value: stake + agentDep}(claimId, "claim is fraudulent");
        platform.fireSuccess(_lastReq(), "PAYER"); // overturned

        uint256 before = funder.balance;
        uint256 insuredBefore = insured.balance;
        court.finalize(caseId);

        assertEq(funder.balance, before + stake); // stake returned
        assertEq(insured.balance, insuredBefore); // no payout
    }

    function test_appeal_byPoolFunder_upheld_slashesStake_toInsured() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // pool loses round 0

        uint256 caseId = _caseId(claimId);
        uint256 stake = (COVERAGE * ins.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(funder);
        ins.appealClaim{value: stake + agentDep}(claimId, "still bogus");
        platform.fireSuccess(_lastReq(), "PAYEE"); // upheld

        uint256 cut = (stake * ins.keeperCutBps()) / 10000;
        uint256 toWinner = stake - cut;
        uint256 insuredBefore = insured.balance;
        uint256 trBefore = treasury.balance;
        court.finalize(caseId);

        // insured gets coverage + slashed stake (minus treasury cut)
        assertEq(insured.balance, insuredBefore + COVERAGE + toWinner);
        assertEq(treasury.balance, trBefore + cut);
    }

    function test_appeal_byNonFunder_reverts_onPayeeVerdict() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        uint256 claimId = _fileClaim(policyId, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE");

        uint256 caseId = _caseId(claimId);
        uint256 stake = (COVERAGE * ins.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(stranger);
        vm.expectRevert(bytes("only pool funder"));
        ins.appealClaim{value: stake + agentDep}(claimId, "x");
    }

    function test_withdrawPool_blockedWhileClaimFiled() public {
        _fund(funder, 10 ether);
        uint256 policyId = _policy();
        _fileClaim(policyId, "ev0");
        // do NOT fire/finalize -- claim still Filed
        vm.prank(funder);
        vm.expectRevert(bytes("claims open"));
        ins.withdrawPool(1 ether);
    }

    function test_withdrawPool_proRata_afterSettlement() public {
        _fund(funder, 6 ether);
        _fund(funder2, 4 ether);
        uint256 policyId = _policy(); // adds 0.05 ether premium
        uint256 claimId = _fileClaim(policyId, "ev0");
        platform.fireSuccess(_lastReq(), "PAYER"); // no payout
        uint256 caseId = _caseId(claimId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        // pool = 10 + 0.05; shares = 10. funder owns 60%, funder2 owns 40%.
        uint256 pool = ins.totalPool();
        uint256 sharesAll = ins.totalShares();
        uint256 funderShares = ins.shares(funder);
        uint256 expectedF = (funderShares * pool) / sharesAll;

        uint256 before = funder.balance;
        vm.prank(funder);
        ins.withdrawPool(funderShares);
        assertEq(funder.balance, before + expectedF);
        assertEq(ins.shares(funder), 0);
    }

    function test_expiredPolicy_cannotFileClaim() public {
        _fund(funder, 10 ether);
        uint256 premium = (COVERAGE * ins.premiumBps()) / 10000;
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(insured);
        uint256 policyId = ins.createPolicy{value: premium}(COVERAGE, expiry);

        vm.warp(uint256(expiry) + 1);
        uint256 fee = court.quoteOpen();
        vm.prank(insured);
        vm.expectRevert(bytes("policy expired"));
        ins.fileClaim{value: fee}(policyId, "too late");
    }

    function test_onVerdict_onlyCourt() public {
        vm.expectRevert(bytes("only court"));
        ins.onVerdict(1, Verdict.PAYEE);
    }

    function test_admin_setPremiumBps() public {
        ins.setPremiumBps(750);
        assertEq(ins.premiumBps(), 750);
    }

    function test_admin_setPremiumBps_rejectsNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not owner"));
        ins.setPremiumBps(100);
    }
}
