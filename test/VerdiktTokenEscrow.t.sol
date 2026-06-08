// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktTokenEscrow} from "../src/VerdiktTokenEscrow.sol";
import {IVerdiktCourt, Verdict, CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FeeOnTransferERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
    }
}

contract ReentrantERC20 {
    VerdiktTokenEscrow public target;
    address public reentryPayee;
    uint64 public reentryDeliverBy;
    bool public attack = true;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function configureAttack(VerdiktTokenEscrow target_, address payee_, uint64 deliverBy_) external {
        target = target_;
        reentryPayee = payee_;
        reentryDeliverBy = deliverBy_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (attack) {
            attack = false;
            try target.createDeal(reentryPayee, 1, reentryDeliverBy) returns (uint256) {
                revert("reentry succeeded");
            } catch Error(string memory reason) {
                require(keccak256(bytes(reason)) == keccak256(bytes("reentrant")), "unexpected reentry failure");
            }
        }
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract VerdiktTokenEscrowTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktTokenEscrow escrow;
    MockERC20 token;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");
    address stranger = makeAddr("stranger");

    uint256 constant AMOUNT = 1000e18;

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        token = new MockERC20();
        escrow = new VerdiktTokenEscrow(address(court), treasury, address(token));
        vm.deal(payer, 100 ether);
        vm.deal(payee, 100 ether);
        vm.deal(stranger, 100 ether);
        token.mint(payer, 10_000e18);
        vm.prank(payer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    function _caseId(uint256 dealId) internal view returns (uint256 c) {
        (,,,,, c) = escrow.deals(dealId);
    }

    function _newDeal() internal returns (uint256 dealId) {
        vm.prank(payer);
        dealId = escrow.createDeal(payee, AMOUNT, uint64(block.timestamp + 1 days));
    }

    function _dispute(uint256 dealId, address who, string memory ev) internal {
        uint256 fee = court.quoteOpen();
        vm.prank(who);
        escrow.dispute{value: fee}(dealId, ev);
    }

    function test_createDeal_pullsTokens() public {
        uint256 payerBefore = token.balanceOf(payer);
        uint256 dealId = _newDeal();
        assertEq(token.balanceOf(payer), payerBefore - AMOUNT);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        (,, uint256 amount, VerdiktTokenEscrow.DealStatus st,,) = escrow.deals(dealId);
        assertEq(amount, AMOUNT);
        assertEq(uint8(st), uint8(VerdiktTokenEscrow.DealStatus.Funded));
    }

    function test_createDeal_acceptsNoReturnToken() public {
        NoReturnERC20 noReturn = new NoReturnERC20();
        VerdiktTokenEscrow e = new VerdiktTokenEscrow(address(court), treasury, address(noReturn));
        noReturn.mint(payer, AMOUNT);
        vm.prank(payer);
        noReturn.approve(address(e), type(uint256).max);

        vm.prank(payer);
        uint256 dealId = e.createDeal(payee, AMOUNT, uint64(block.timestamp + 1 days));

        assertEq(noReturn.balanceOf(payer), 0);
        assertEq(noReturn.balanceOf(address(e)), AMOUNT);
        (,, uint256 amount, VerdiktTokenEscrow.DealStatus st,,) = e.deals(dealId);
        assertEq(amount, AMOUNT);
        assertEq(uint8(st), uint8(VerdiktTokenEscrow.DealStatus.Funded));
    }

    function test_createDeal_rejectsFeeOnTransferToken() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        VerdiktTokenEscrow e = new VerdiktTokenEscrow(address(court), treasury, address(feeToken));
        feeToken.mint(payer, AMOUNT);
        vm.prank(payer);
        feeToken.approve(address(e), type(uint256).max);

        vm.prank(payer);
        vm.expectRevert(bytes("fee token unsupported"));
        e.createDeal(payee, AMOUNT, uint64(block.timestamp + 1 days));
    }

    function test_createDeal_blocksReentrantTokenCallback() public {
        ReentrantERC20 reentrantToken = new ReentrantERC20();
        VerdiktTokenEscrow e = new VerdiktTokenEscrow(address(court), treasury, address(reentrantToken));
        reentrantToken.configureAttack(e, payee, uint64(block.timestamp + 1 days));
        reentrantToken.mint(payer, AMOUNT);
        vm.prank(payer);
        reentrantToken.approve(address(e), type(uint256).max);

        vm.prank(payer);
        uint256 dealId = e.createDeal(payee, AMOUNT, uint64(block.timestamp + 1 days));

        assertEq(dealId, 1);
        assertEq(e.nextDealId(), 2);
    }

    function test_dispute_payeeWins_creditsAndWithdraws() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "goods delivered as agreed");
        platform.fireSuccess(_lastReq(), "PAYEE");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        assertEq(escrow.pending(payee), AMOUNT);
        assertEq(escrow.pending(payer), 0);

        uint256 before = token.balanceOf(payee);
        vm.prank(payee);
        escrow.withdraw();
        assertEq(token.balanceOf(payee), before + AMOUNT);
        assertEq(escrow.pending(payee), 0);

        (,,, VerdiktTokenEscrow.DealStatus st,,) = escrow.deals(dealId);
        assertEq(uint8(st), uint8(VerdiktTokenEscrow.DealStatus.Settled));
    }

    function test_dispute_overpaymentCreditsNativeRefund() public {
        uint256 dealId = _newDeal();
        uint256 fee = court.quoteOpen();
        uint256 before = payer.balance;
        vm.prank(payer);
        escrow.dispute{value: fee + 1 ether}(dealId, "ev");

        assertEq(payer.balance, before - fee - 1 ether);
        assertEq(escrow.nativePending(payer), 1 ether);

        vm.prank(payer);
        escrow.withdrawNative();
        assertEq(payer.balance, before - fee);
    }

    function test_dispute_payerWins_creditsAndWithdraws() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payee, "never received anything");
        platform.fireSuccess(_lastReq(), "PAYER");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        assertEq(escrow.pending(payer), AMOUNT);
        assertEq(escrow.pending(payee), 0);

        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        escrow.withdraw();
        assertEq(token.balanceOf(payer), before + AMOUNT);
    }

    function test_dispute_split_creditsHalves() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "partially delivered");
        platform.fireSuccess(_lastReq(), "SPLIT");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        assertEq(escrow.pending(payer), AMOUNT / 2);
        assertEq(escrow.pending(payee), AMOUNT - AMOUNT / 2);

        uint256 pBefore = token.balanceOf(payer);
        uint256 eBefore = token.balanceOf(payee);
        vm.prank(payer);
        escrow.withdraw();
        vm.prank(payee);
        escrow.withdraw();
        assertEq(token.balanceOf(payer), pBefore + AMOUNT / 2);
        assertEq(token.balanceOf(payee), eBefore + (AMOUNT - AMOUNT / 2));
    }

    function test_dispute_gradedSplit75_creditsPayeeShare() public {
        court.setGradedSplit(true);
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "mostly delivered");
        platform.fireSuccess(_lastReq(), "SPLIT75");

        uint256 caseId = _caseId(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        assertEq(escrow.pending(payer), AMOUNT / 4);
        assertEq(escrow.pending(payee), AMOUNT - AMOUNT / 4);
    }

    function test_appeal_upheld_slashesStake() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // payer loses round 0

        uint256 caseId = _caseId(dealId);
        uint256 stake = (AMOUNT * escrow.appealStakeBps()) / 10000; // 10%
        uint256 agentDep = court.quoteAppeal(caseId);

        uint256 payerTokBefore = token.balanceOf(payer);
        vm.prank(payer);
        escrow.appeal{value: agentDep}(dealId, "new evidence");
        // stake pulled in token
        assertEq(token.balanceOf(payer), payerTokBefore - stake);

        platform.fireSuccess(_lastReq(), "PAYEE"); // upheld on appeal
        court.finalize(caseId); // round 1 == MAX_ROUND, finalize immediately

        uint256 cut = (stake * escrow.keeperCutBps()) / 10000;
        uint256 toWinner = stake - cut;
        // payee wins deal amount + slashed stake (minus treasury cut)
        assertEq(escrow.pending(payee), AMOUNT + toWinner);
        assertEq(escrow.pending(treasury), cut);
        // exact conservation
        assertEq(toWinner + cut, stake);
    }

    function test_appeal_overturned_returnsStake() public {
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "ev0");
        platform.fireSuccess(_lastReq(), "PAYEE"); // payer loses round 0

        uint256 caseId = _caseId(dealId);
        uint256 stake = (AMOUNT * escrow.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(payer);
        escrow.appeal{value: agentDep}(dealId, "compelling new evidence");

        platform.fireSuccess(_lastReq(), "PAYER"); // overturned
        court.finalize(caseId);

        // payer gets the deal amount back plus the returned stake
        assertEq(escrow.pending(payer), AMOUNT + stake);
        assertEq(escrow.pending(payee), 0);

        uint256 before = token.balanceOf(payer);
        vm.prank(payer);
        escrow.withdraw();
        assertEq(token.balanceOf(payer), before + AMOUNT + stake);
    }

    function test_gradedSplitAppeal_changedBpsReturnsStake() public {
        court.setGradedSplit(true);
        uint256 dealId = _newDeal();
        _dispute(dealId, payer, "partial delivery");
        platform.fireSuccess(_lastReq(), "SPLIT25");

        uint256 caseId = _caseId(dealId);
        uint256 stake = (AMOUNT * escrow.appealStakeBps()) / 10000;
        uint256 agentDep = court.quoteAppeal(caseId);
        vm.prank(payer);
        escrow.appeal{value: agentDep}(dealId, "more delivery evidence");
        platform.fireSuccess(_lastReq(), "SPLIT75");

        court.finalize(caseId);
        assertEq(escrow.pending(payer), AMOUNT / 4 + stake);
        assertEq(escrow.pending(payee), AMOUNT - AMOUNT / 4);
        assertEq(escrow.pending(treasury), 0);
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
        vm.prank(payee); // winner cannot appeal
        vm.expectRevert(bytes("only losing party"));
        escrow.appeal{value: agentDep}(dealId, "x");
    }
}
