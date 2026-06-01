// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Abstention: when allowAbstention is on, the panel may answer UNDECIDABLE instead of being
/// forced to pick a winner on thin evidence. Consumers settle UNDECIDABLE to the safe default —
/// refund the payer/depositor (burden of proof on the claimant).
contract AbstentionTest is Test {
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
        vm.deal(address(this), 100 ether);
        vm.deal(payer, 100 ether);
    }

    receive() external payable {}

    function _allowed() internal view returns (string[] memory allowed) {
        (,,, bytes memory payload,,,,) = platform.requests(platform.nextId() - 1);
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        string memory prompt;
        string memory system;
        bool cot;
        (prompt, system, cot, allowed) = abi.decode(args, (string, string, bool, string[]));
    }

    function _offersUndecidable() internal view returns (bool) {
        string[] memory a = _allowed();
        for (uint256 i = 0; i < a.length; i++) {
            if (keccak256(bytes(a[i])) == keccak256("UNDECIDABLE")) return true;
        }
        return false;
    }

    // --- court toggle ---------------------------------------------------------

    function test_default_off_andOwnerOnly() public {
        assertFalse(court.allowAbstention());
        vm.prank(stranger);
        vm.expectRevert(bytes("not owner"));
        court.setAllowAbstention(true);
        court.setAllowAbstention(true);
        assertTrue(court.allowAbstention());
    }

    function test_offered_only_whenEnabled() public {
        court.openCase{value: court.quoteOpen()}(1, "thin evidence");
        assertFalse(_offersUndecidable(), "must not offer UNDECIDABLE when off");

        court.setAllowAbstention(true);
        court.openCase{value: court.quoteOpen()}(2, "thin evidence");
        assertTrue(_offersUndecidable(), "must offer UNDECIDABLE when on");
        // base labels remain (determinism of the existing set preserved)
        assertEq(_allowed().length, 4); // PAYEE/PAYER/SPLIT + UNDECIDABLE
    }

    // --- consumer settlement --------------------------------------------------

    function test_escrow_undecidable_refundsPayer() public {
        court.setAllowAbstention(true);
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(payee, uint64(block.timestamp + 1 days));
        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, "unclear who is right");

        platform.fireSuccess(platform.nextId() - 1, "UNDECIDABLE");
        (,,,, uint256 caseId) = _deal(dealId); // caseId via deals() tuple
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);

        // panel abstained -> the payer (depositor) is made whole, payee gets nothing
        assertEq(escrow.pending(payer), 1 ether, "payer should be refunded in full");
        assertEq(escrow.pending(payee), 0, "payee should receive nothing");
        assertEq(uint8(court.getCase(caseId).verdict), uint8(Verdict.UNDECIDABLE), "verdict recorded as UNDECIDABLE");
    }

    function _deal(uint256 dealId) internal view returns (address, address, uint256, uint8, uint256 caseId) {
        (address p, address pe, uint256 amt, VerdiktEscrow.DealStatus st,, uint256 cid) = escrow.deals(dealId);
        return (p, pe, amt, uint8(st), cid);
    }
}
