// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice The prompt is the court's "legal code": versioned, immutable per version, governable,
/// and snapshotted per case so every verdict is auditable against the exact prompt that decided it.
contract PromptGovernanceTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    address gov = makeAddr("gov"); // a stand-in for the timelock owner

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    function _open(string memory ev) internal returns (uint256 caseId) {
        caseId = court.openCase{value: court.quoteOpen()}(1, ev);
    }

    function _dispatchedSystem() internal view returns (string memory system) {
        (,,, bytes memory payload,,,,) = platform.requests(platform.nextId() - 1);
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        string memory prompt;
        bool cot;
        string[] memory allowed;
        (prompt, system, cot, allowed) = abi.decode(args, (string, string, bool, string[]));
    }

    function _contains(string memory h, string memory n) internal pure returns (bool) {
        bytes memory hb = bytes(h);
        bytes memory nb = bytes(n);
        if (nb.length == 0 || hb.length < nb.length) return false;
        for (uint256 i = 0; i <= hb.length - nb.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < nb.length; j++) {
                if (hb[i + j] != nb[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }

    // --- seeding --------------------------------------------------------------

    function test_version1_seeded_andActive() public view {
        assertEq(court.promptVersionCount(), 1);
        assertEq(court.activePromptVersion(), 1);
        VerdiktCourt.PromptVersion memory v1 = court.promptVersion(1);
        assertTrue(v1.exists);
        assertTrue(_contains(v1.system, "untrusted"), "seeded v1 must carry the hardened system prompt");
    }

    // --- publishing (append-only, governed) -----------------------------------

    function test_publish_isAppendOnly_andOwnerOnly() public {
        VerdiktCourt.PromptVersion memory v1Before = court.promptVersion(1);
        uint256 id =
            court.publishPromptVersion("SYS v2", "PRE v2\n<evidence>\n", "\n</evidence>\nNG", "\n</evidence>\nG");
        assertEq(id, 2);
        assertEq(court.promptVersionCount(), 2);
        // v1 is untouched
        assertEq(court.promptVersion(1).system, v1Before.system);
        // not auto-activated
        assertEq(court.activePromptVersion(), 1);

        vm.prank(gov);
        vm.expectRevert(bytes("not owner"));
        court.publishPromptVersion("x", "x", "x", "x");
    }

    function test_publish_rejectsEmptyField() public {
        vm.expectRevert(bytes("empty prompt"));
        court.publishPromptVersion("", "p", "n", "g");
    }

    function test_setActive_ownerOnly_andUnknownReverts() public {
        court.publishPromptVersion("SYS v2", "PRE v2\n<evidence>\n", "\n</evidence>\nNG", "\n</evidence>\nG");
        vm.expectRevert(bytes("no such version"));
        court.setActivePromptVersion(99);
        vm.prank(gov);
        vm.expectRevert(bytes("not owner"));
        court.setActivePromptVersion(2);
        court.setActivePromptVersion(2);
        assertEq(court.activePromptVersion(), 2);
    }

    // --- per-case snapshot ----------------------------------------------------

    function test_caseSnapshotsActiveVersion() public {
        uint256 c1 = _open("a");
        assertEq(court.promptVersionOf(c1), 1);

        court.publishPromptVersion(
            "SYS v2 distinctive", "PRE v2\n<evidence>\n", "\n</evidence>\nNG", "\n</evidence>\nG"
        );
        court.setActivePromptVersion(2);
        uint256 c2 = _open("b");
        assertEq(court.promptVersionOf(c2), 2);
        // the earlier case stays on v1 even after the active version moved
        assertEq(court.promptVersionOf(c1), 1);
    }

    function test_buildPayload_usesCaseVersion() public {
        // case under v1 uses the hardened system prompt
        _open("a");
        assertTrue(_contains(_dispatchedSystem(), "untrusted"), "case 1 should use v1 system");

        court.publishPromptVersion(
            "SYS v2 distinctive marker", "PRE v2\n<evidence>\n", "\n</evidence>\nNG", "\n</evidence>\nG"
        );
        court.setActivePromptVersion(2);
        _open("b");
        assertTrue(_contains(_dispatchedSystem(), "SYS v2 distinctive marker"), "case 2 should use v2 system");
    }

    function test_appealKeepsSnapshottedVersion() public {
        uint256 caseId = _open("partial delivery");
        platform.fireSuccess(platform.nextId() - 1, "PAYEE"); // case -> Ruled

        court.publishPromptVersion("SYS v2", "PRE v2\n<evidence>\n", "\n</evidence>\nNG", "\n</evidence>\nG");
        court.setActivePromptVersion(2);

        court.appeal{value: court.quoteAppeal(caseId)}(caseId, "new evidence");
        // the law in force when the case opened still governs the appeal
        assertEq(court.promptVersionOf(caseId), 1);
        assertTrue(_contains(_dispatchedSystem(), "untrusted"), "appeal must reuse v1 system");
    }
}
