// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktAgentEscrow} from "../src/VerdiktAgentEscrow.sol";
import {IVerdiktCourt, Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice An autonomous buyer agent. No EOA owner in the settlement path: it funds deals,
/// opens disputes with machine-generated evidence, and pulls its refund — all on-chain.
contract BuyerAgent {
    VerdiktAgentEscrow public immutable escrow;
    VerdiktCourt public immutable court;

    constructor(VerdiktAgentEscrow escrow_, VerdiktCourt court_) {
        escrow = escrow_;
        court = court_;
    }

    function fund(address sellerAgent, uint64 deliverBy) external payable returns (uint256 dealId) {
        dealId = escrow.createDeal{value: msg.value}(sellerAgent, deliverBy);
    }

    /// @notice Assemble evidence programmatically and open a court case for the deal.
    function openDispute(uint256 dealId, uint64 deliverBy) external returns (uint256) {
        return openDispute(dealId, deliverBy, 0);
    }

    /// @notice Dispute selecting a trial panel size (0 = default 5), so the agent degrades to the
    /// validators currently available instead of having its dispute revert.
    function openDispute(uint256 dealId, uint64 deliverBy, uint8 trialPanel) public returns (uint256) {
        string memory evidence = string.concat(
            "AGENT-GENERATED COMPLAINT\n",
            "deal=",
            _toString(dealId),
            "\ndeliverBy=",
            _toString(deliverBy),
            "\nnow=",
            _toString(block.timestamp),
            "\nclaim=seller did not mark delivery before the deadline; payment should be refunded to the payer"
        );
        if (trialPanel == 0) {
            uint256 fee = court.quoteOpen();
            escrow.dispute{value: fee}(dealId, evidence);
            return fee;
        }
        uint256 panelFee = court.quoteOpen(trialPanel);
        escrow.dispute{value: panelFee}(dealId, evidence, trialPanel);
        return panelFee;
    }

    function claim() external returns (uint256) {
        return escrow.withdraw();
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    receive() external payable {}
}

/// @notice An autonomous seller agent. It is a contract counterparty (not an EOA) and can
/// pull whatever settlement credited to it.
contract SellerAgent {
    VerdiktAgentEscrow public immutable escrow;

    constructor(VerdiktAgentEscrow escrow_) {
        escrow = escrow_;
    }

    function claim() external returns (uint256) {
        return escrow.withdraw();
    }

    receive() external payable {}
}

/// @notice A seller agent that REVERTS on any ETH receipt. Used to prove the non-bricking
/// property: even when the counterparty rejects ETH, pull-payment settlement still credits
/// `pending` and the honest agent exits with `withdraw()`.
contract RevertingSellerAgent {
    VerdiktAgentEscrow public immutable escrow;

    constructor(VerdiktAgentEscrow escrow_) {
        escrow = escrow_;
    }

    function claim() external returns (uint256) {
        return escrow.withdraw();
    }

    receive() external payable {
        revert("seller rejects ETH");
    }
}

contract AgentToAgentDemoTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktAgentEscrow escrow;

    address treasury = makeAddr("treasury");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktAgentEscrow(address(court), treasury);
    }

    function _lastReq() internal view returns (uint256) {
        return platform.nextId() - 1;
    }

    /// @dev Flagship demo: two contract agents settle a dispute with no EOA in the loop.
    /// Buyer funds, seller never delivers, buyer disputes with machine-generated evidence,
    /// the panel rules PAYER, the case finalizes, and the buyer pulls its refund.
    function test_agentToAgent_buyerRefundedViaPullPayment() public {
        BuyerAgent buyer = new BuyerAgent(escrow, court);
        SellerAgent seller = new SellerAgent(escrow);

        // Fund the buyer agent so it (a contract) can act fully autonomously.
        vm.deal(address(buyer), 5 ether);

        uint64 deliverBy = uint64(block.timestamp + 1 days);
        uint256 dealId = buyer.fund{value: 1 ether}(address(seller), deliverBy);

        // SellerAgent does NOT call markDelivered. Buyer opens a dispute with assembled evidence.
        buyer.openDispute(dealId, deliverBy);

        // Mock panel rules in the payer's (buyer's) favor.
        platform.fireSuccess(_lastReq(), "PAYER");

        // Permissionless finalize after the appeal window — driven here without any EOA party.
        (,,,,, uint256 caseId) = escrow.deals(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        // Settlement credited the buyer's pending balance; nothing was pushed.
        assertEq(escrow.pending(address(buyer)), 1 ether, "buyer credited full refund");
        assertEq(escrow.pending(address(seller)), 0, "seller credited nothing");

        // Pull-payment loop: the buyer contract withdraws its own funds.
        uint256 before = address(buyer).balance;
        uint256 got = buyer.claim();
        assertEq(got, 1 ether, "withdraw returns credited amount");
        assertEq(address(buyer).balance, before + 1 ether, "buyer contract received the refund");
        assertEq(escrow.pending(address(buyer)), 0, "pending cleared after withdraw");
    }

    /// @dev Non-bricking safety: a counterparty that reverts on ETH receipt cannot brick
    /// settlement. The panel rules SPLIT (crediting both sides), finalize still succeeds, and
    /// the honest buyer still exits via withdraw() even though the seller can never receive ETH.
    function test_revertingCounterparty_cannotBrickSettlement() public {
        BuyerAgent buyer = new BuyerAgent(escrow, court);
        RevertingSellerAgent seller = new RevertingSellerAgent(escrow);

        vm.deal(address(buyer), 5 ether);

        uint64 deliverBy = uint64(block.timestamp + 1 days);
        uint256 dealId = buyer.fund{value: 1 ether}(address(seller), deliverBy);
        buyer.openDispute(dealId, deliverBy);

        // SPLIT credits BOTH parties, so the reverting seller is owed funds too.
        platform.fireSuccess(_lastReq(), "SPLIT");

        (,,,,, uint256 caseId) = escrow.deals(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);

        // finalize() must NOT revert even though the seller rejects ETH — settlement only credits.
        court.finalize(caseId);
        assertEq(escrow.pending(address(buyer)), 0.5 ether, "buyer credited its half");
        assertEq(escrow.pending(address(seller)), 0.5 ether, "reverting seller still credited");

        // Honest buyer exits cleanly.
        uint256 before = address(buyer).balance;
        uint256 got = buyer.claim();
        assertEq(got, 0.5 ether, "honest buyer withdrew its credited half");
        assertEq(address(buyer).balance, before + 0.5 ether, "honest buyer received ETH despite bad counterparty");
        assertEq(escrow.pending(address(buyer)), 0, "buyer pending cleared");

        // The reverting seller's own withdraw reverts (its choice), but it never blocked anyone.
        vm.expectRevert(bytes("withdraw failed"));
        seller.claim();
    }

    /// @dev Resilience: when the network is below full strength, an agent disputes at a smaller
    /// trial panel instead of reverting. The court convenes exactly that panel and settles normally.
    function test_agentToAgent_degradedTrialPanel() public {
        BuyerAgent buyer = new BuyerAgent(escrow, court);
        SellerAgent seller = new SellerAgent(escrow);
        vm.deal(address(buyer), 5 ether);

        uint64 deliverBy = uint64(block.timestamp + 1 days);
        uint256 dealId = buyer.fund{value: 1 ether}(address(seller), deliverBy);

        // Dispute at a 3-validator panel (e.g. only 3 validators available) rather than the default 5.
        buyer.openDispute(dealId, deliverBy, 3);

        // The court convened exactly a 3-juror panel (majority threshold 2), not the default 5.
        (,,,, uint256 subSize, uint256 threshold,,) = platform.requests(_lastReq());
        assertEq(subSize, 3, "trial panel degraded to 3");
        assertEq(threshold, 2, "majority threshold for 3 jurors");

        platform.fireSuccess(_lastReq(), "PAYER");
        (,,,,, uint256 caseId) = escrow.deals(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        assertEq(escrow.pending(address(buyer)), 1 ether, "buyer refunded at panel 3");
        assertEq(buyer.claim(), 1 ether, "buyer pulls refund");
    }

    /// @dev The trial panel is bounded [MIN_TRIAL_PANEL, 5]; the quote is monotonic and the
    /// 5-panel quote equals the default no-arg quote.
    function test_quoteOpen_panelBounds() public {
        vm.expectRevert(bytes("panel out of range"));
        court.quoteOpen(2);
        vm.expectRevert(bytes("panel out of range"));
        court.quoteOpen(6);
        assertLt(court.quoteOpen(3), court.quoteOpen(5));
        assertEq(court.quoteOpen(5), court.quoteOpen());
    }
}
