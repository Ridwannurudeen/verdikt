// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {IVerdiktCourt, Verdict, CaseStatus, CaseView} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Drives VerdiktEscrow through its full lifecycle (create -> dispute -> verdict ->
/// appeal -> finalize) with bounded, randomized actions so the invariants below are exercised
/// against arbitrary interleavings. The handler also records ground-truth accounting (funded
/// amounts, posted stakes, money actually paid out to the parties/treasury) that the invariant
/// functions read back. Court fees and excess refunds are intentionally excluded from escrow
/// fund-conservation: they leave the escrow as the agent deposit and never re-enter the pool of
/// escrowed value, which is exactly what conservation should ignore.
contract EscrowHandler is Test {
    MockAgentRequester public platform;
    VerdiktCourt public court;
    VerdiktEscrow public escrow;

    address public payer = makeAddr("h_payer");
    address public payee = makeAddr("h_payee");
    address public treasury;

    // ground-truth accounting
    uint256 public totalFunded; // sum of deal amounts ever escrowed
    uint256 public totalStaked; // sum of appeal stakes ever posted
    uint256 public totalPaidOut; // ETH credited to payer + payee + treasury on settlement

    // outstanding obligations the escrow still holds custody of
    uint256 public outstanding;

    // bookkeeping for the active set of deals
    uint256[] public dealIds;
    mapping(uint256 => bool) public appealed; // dealId => appeal posted
    mapping(uint256 => bool) public settled; // dealId => onVerdict ran (guards double settle)

    string[3] internal VERDICTS = ["PAYEE", "PAYER", "SPLIT"];

    constructor(MockAgentRequester platform_, VerdiktCourt court_, VerdiktEscrow escrow_, address treasury_) {
        platform = platform_;
        court = court_;
        escrow = escrow_;
        treasury = treasury_;
        vm.deal(payer, 1_000_000 ether);
        vm.deal(payee, 1_000_000 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _dealCaseId(uint256 dealId) internal view returns (uint256 c) {
        (,,,,, c) = escrow.deals(dealId);
    }

    function _dealStatus(uint256 dealId) internal view returns (VerdiktEscrow.DealStatus st) {
        (,,, st,,) = escrow.deals(dealId);
    }

    function _dealAmount(uint256 dealId) internal view returns (uint256 a) {
        (,, a,,,) = escrow.deals(dealId);
    }

    // --- bounded actions ------------------------------------------------------

    function createDeal(uint256 amount) public {
        amount = bound(amount, 1 wei, 100 ether);
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: amount}(payee, uint64(block.timestamp + 1 days));
        dealIds.push(dealId);
        totalFunded += amount;
        outstanding += amount;
    }

    function dispute(uint256 seed) public {
        uint256 dealId = _pickDeal(seed);
        if (dealId == 0) return;
        VerdiktEscrow.DealStatus st = _dealStatus(dealId);
        if (st != VerdiktEscrow.DealStatus.Funded && st != VerdiktEscrow.DealStatus.Delivered) return;

        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "evidence");
    }

    function ruleVerdict(uint256 seed, uint256 verdictSeed) public {
        uint256 dealId = _pickDeal(seed);
        if (dealId == 0) return;
        if (_dealStatus(dealId) != VerdiktEscrow.DealStatus.Disputed) return;
        uint256 caseId = _dealCaseId(dealId);
        CaseView memory cv = court.getCase(caseId);
        if (cv.status != CaseStatus.Pending) return;
        platform.fireSuccess(_lastReq(), VERDICTS[verdictSeed % 3]);
    }

    function appeal(uint256 seed) public {
        uint256 dealId = _pickDeal(seed);
        if (dealId == 0) return;
        if (_dealStatus(dealId) != VerdiktEscrow.DealStatus.Disputed) return;
        if (appealed[dealId]) return;
        uint256 caseId = _dealCaseId(dealId);
        CaseView memory cv = court.getCase(caseId);
        if (cv.status != CaseStatus.Ruled) return;
        if (cv.round >= court.MAX_ROUND()) return;

        uint256 amount = _dealAmount(dealId);
        uint256 stake = (amount * escrow.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);

        // the loser of the current verdict is the only party allowed to appeal a non-split ruling.
        address appellant = cv.verdict == Verdict.PAYEE ? payer : cv.verdict == Verdict.PAYER ? payee : payer;
        vm.prank(appellant);
        escrow.appeal{value: stake + agentDep}(dealId, "new evidence");

        appealed[dealId] = true;
        totalStaked += stake;
        outstanding += stake;
    }

    function finalize(uint256 seed) public {
        uint256 dealId = _pickDeal(seed);
        if (dealId == 0) return;
        if (_dealStatus(dealId) != VerdiktEscrow.DealStatus.Disputed) return;
        if (settled[dealId]) return;
        uint256 caseId = _dealCaseId(dealId);
        CaseView memory cv = court.getCase(caseId);
        if (cv.status != CaseStatus.Ruled) return;
        if (cv.round != court.MAX_ROUND() && block.timestamp <= cv.rulingTime + court.appealWindow()) return;

        uint256 amount = _dealAmount(dealId);
        uint256 payerBefore = escrow.pending(payer);
        uint256 payeeBefore = escrow.pending(payee);
        uint256 treasBefore = escrow.pending(treasury);

        court.finalize(caseId);

        settled[dealId] = true;

        uint256 paid =
            (escrow.pending(payer) - payerBefore) + (escrow.pending(payee) - payeeBefore)
                + (escrow.pending(treasury) - treasBefore);
        totalPaidOut += paid;

        // obligation discharged: the deal amount plus any stake leaves the escrow's custody.
        outstanding -= amount;
        if (appealed[dealId]) outstanding -= (amount * escrow.appealStakeBps()) / 10000;
    }

    function warp(uint256 dt) public {
        dt = bound(dt, 1, 2 hours);
        vm.warp(block.timestamp + dt);
    }

    function _pickDeal(uint256 seed) internal view returns (uint256) {
        if (dealIds.length == 0) return 0;
        return dealIds[seed % dealIds.length];
    }

    function dealCount() external view returns (uint256) {
        return dealIds.length;
    }
}

contract VerdiktEscrowInvariantTest is StdInvariant, Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;
    EscrowHandler handler;

    address treasury = makeAddr("inv_treasury");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        handler = new EscrowHandler(platform, court, escrow, treasury);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = EscrowHandler.createDeal.selector;
        selectors[1] = EscrowHandler.dispute.selector;
        selectors[2] = EscrowHandler.ruleVerdict.selector;
        selectors[3] = EscrowHandler.appeal.selector;
        selectors[4] = EscrowHandler.finalize.selector;
        selectors[5] = EscrowHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Invariant 1 (fund conservation): the escrow never pays out more than the value that was
    /// put into it — every wei delivered to a party traces back to a funded deal or a posted stake.
    function invariant_payoutsNeverExceedInflows() public view {
        assertLe(handler.totalPaidOut(), handler.totalFunded() + handler.totalStaked());
    }

    /// Invariant 4 (solvency): the escrow's ETH balance always fully backs its outstanding
    /// obligations (un-settled deal amounts + held appeal stakes). It can never become insolvent.
    function invariant_solvency() public view {
        assertGe(address(escrow).balance, handler.outstanding());
    }

    /// Invariant: the running outstanding obligation equals funded + staked minus what was paid
    /// out, so no money is silently created or destroyed across the lifecycle.
    function invariant_outstandingAccounting() public view {
        assertEq(handler.outstanding(), handler.totalFunded() + handler.totalStaked() - handler.totalPaidOut());
    }
}

/// @notice Stateless fuzz + targeted unit coverage for the value-conservation properties that are
/// hard to reach from a single random walk: the _split payout sum across every verdict, the
/// stake-slash split (toWinner + treasuryCut == stake), and the status guards against double
/// settlement. Each test drives the public dispute -> verdict -> finalize path end to end.
contract VerdiktEscrowConservationTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;

    address payer = makeAddr("c_payer");
    address payee = makeAddr("c_payee");
    address treasury = makeAddr("c_treasury");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        vm.deal(payer, 1_000_000 ether);
        vm.deal(payee, 1_000_000 ether);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 dealId) internal view returns (uint256 c) {
        (,,,,, c) = escrow.deals(dealId);
    }

    function _newDeal(uint256 amount) internal returns (uint256 dealId) {
        vm.prank(payer);
        dealId = escrow.createDeal{value: amount}(payee, uint64(block.timestamp + 1 days));
    }

    function _disputeAndRule(uint256 dealId, string memory verdict) internal returns (uint256 caseId) {
        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "ev");
        platform.fireSuccess(_lastReq(), verdict);
        caseId = _caseId(dealId);
    }

    // --- Invariant 2 driver: _split payout sums to the deal amount for every verdict ----------

    function testFuzz_split_payeeWins_paysFullAmount(uint256 amount) public {
        amount = bound(amount, 1 wei, 100 ether);
        uint256 dealId = _newDeal(amount);
        uint256 caseId = _disputeAndRule(dealId, "PAYEE");

        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 pBefore = escrow.pending(payer);
        uint256 eBefore = escrow.pending(payee);
        court.finalize(caseId);

        uint256 toPayer = escrow.pending(payer) - pBefore;
        uint256 toPayee = escrow.pending(payee) - eBefore;
        assertEq(toPayer, 0);
        assertEq(toPayee, amount);
        assertEq(toPayer + toPayee, amount);
    }

    function testFuzz_split_payerWins_refundsFullAmount(uint256 amount) public {
        amount = bound(amount, 1 wei, 100 ether);
        uint256 dealId = _newDeal(amount);
        uint256 caseId = _disputeAndRule(dealId, "PAYER");

        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 pBefore = escrow.pending(payer);
        uint256 eBefore = escrow.pending(payee);
        court.finalize(caseId);

        uint256 toPayer = escrow.pending(payer) - pBefore;
        uint256 toPayee = escrow.pending(payee) - eBefore;
        assertEq(toPayer, amount);
        assertEq(toPayee, 0);
        assertEq(toPayer + toPayee, amount);
    }

    function testFuzz_split_splitVerdict_sumsToAmount(uint256 amount) public {
        amount = bound(amount, 1 wei, 100 ether);
        uint256 dealId = _newDeal(amount);
        uint256 caseId = _disputeAndRule(dealId, "SPLIT");

        vm.warp(block.timestamp + court.appealWindow() + 1);
        uint256 pBefore = escrow.pending(payer);
        uint256 eBefore = escrow.pending(payee);
        court.finalize(caseId);

        uint256 toPayer = escrow.pending(payer) - pBefore;
        uint256 toPayee = escrow.pending(payee) - eBefore;
        // odd amounts: the remainder wei is routed to the payee, never stranded.
        assertEq(toPayer, amount / 2);
        assertEq(toPayee, amount - amount / 2);
        assertEq(toPayer + toPayee, amount);
    }

    // --- Invariant 2: stake slash splits exactly (toWinner + treasuryCut == stake) -------------

    function testFuzz_appealUpheld_stakeSplitConserved(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 100 ether);
        uint256 dealId = _newDeal(amount);
        uint256 caseId = _disputeAndRule(dealId, "PAYEE"); // payer loses round 0

        uint256 stake = (amount * escrow.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(payer);
        escrow.appeal{value: stake + agentDep}(dealId, "appeal");
        platform.fireSuccess(_lastReq(), "PAYEE"); // upheld -> stake slashed

        uint256 payeeBefore = escrow.pending(payee);
        uint256 treasBefore = escrow.pending(treasury);
        court.finalize(caseId);

        uint256 toWinner = (escrow.pending(payee) - payeeBefore) - amount; // payee also receives the deal amount
        uint256 toTreasury = escrow.pending(treasury) - treasBefore;
        // no wei lost or created: the slashed stake is split exactly between winner and treasury.
        assertEq(toWinner + toTreasury, stake);
    }

    function testFuzz_appealOverturned_stakeReturnedWhole(uint256 amount) public {
        amount = bound(amount, 0.001 ether, 100 ether);
        uint256 dealId = _newDeal(amount);
        uint256 caseId = _disputeAndRule(dealId, "PAYEE"); // payer loses round 0

        uint256 stake = (amount * escrow.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(payer);
        escrow.appeal{value: stake + agentDep}(dealId, "appeal");
        platform.fireSuccess(_lastReq(), "PAYER"); // overturned -> stake returned + refund

        uint256 before = escrow.pending(payer);
        court.finalize(caseId);
        // payer gets the full deal amount back plus the entire stake, no treasury cut.
        assertEq(escrow.pending(payer) - before, amount + stake);
        assertEq(escrow.pending(treasury), 0);
    }

    // --- Invariant 3: no double settle --------------------------------------------------------

    function test_noDoubleFinalize() public {
        uint256 dealId = _newDeal(1 ether);
        uint256 caseId = _disputeAndRule(dealId, "PAYEE");
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        vm.expectRevert(bytes("not ruled"));
        court.finalize(caseId);
    }

    function test_noDoubleSettle_dealStaysSettled() public {
        uint256 dealId = _newDeal(1 ether);
        uint256 caseId = _disputeAndRule(dealId, "PAYEE");
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        (,,, VerdiktEscrow.DealStatus st,,) = escrow.deals(dealId);
        assertEq(uint8(st), uint8(VerdiktEscrow.DealStatus.Settled));

        // a settled deal can no longer be released, disputed, or re-settled.
        vm.prank(payer);
        vm.expectRevert(bytes("bad status"));
        escrow.release(dealId);

        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        vm.expectRevert(bytes("bad status"));
        escrow.dispute{value: fee}(dealId, "again");
    }

    function test_settledDeal_rejectsStaleVerdictCallback() public {
        uint256 dealId = _newDeal(1 ether);
        uint256 caseId = _disputeAndRule(dealId, "PAYEE");
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        // even the court cannot re-settle a deal that already left Disputed.
        vm.prank(address(court));
        vm.expectRevert(bytes("not disputed"));
        escrow.onVerdict(dealId, Verdict.PAYER);
    }
}
