// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktAttestationRegistry} from "../src/VerdiktAttestationRegistry.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice Verifiable evidence: trusted, governed attestors post on-chain facts that the Court folds
/// into the panel prompt as AUTHORITATIVE, above the parties' untrusted claims.
contract AttestationTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktAttestationRegistry registry;

    address courier = makeAddr("courier");
    address stranger = makeAddr("stranger");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        registry = new VerdiktAttestationRegistry();
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    function _prompt() internal view returns (string memory prompt) {
        (,,, bytes memory payload,,,,) = platform.requests(platform.nextId() - 1);
        bytes memory args = new bytes(payload.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = payload[i + 4];
        }
        string memory system;
        bool cot;
        string[] memory allowed;
        (prompt, system, cot, allowed) = abi.decode(args, (string, string, bool, string[]));
    }

    function _indexOf(string memory h, string memory n) internal pure returns (int256) {
        bytes memory hb = bytes(h);
        bytes memory nb = bytes(n);
        if (nb.length == 0 || hb.length < nb.length) return -1;
        for (uint256 i = 0; i <= hb.length - nb.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < nb.length; j++) {
                if (hb[i + j] != nb[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return int256(i);
        }
        return -1;
    }

    function _has(string memory h, string memory n) internal pure returns (bool) {
        return _indexOf(h, n) >= 0;
    }

    function _open(string memory ev) internal {
        court.openCase{value: court.quoteOpen()}(1, ev);
    }

    // --- registry governance --------------------------------------------------

    function test_register_ownerOnly_andEmptyGuards() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not owner"));
        registry.registerAttestor(courier, "Courier");

        vm.expectRevert(bytes("empty label"));
        registry.registerAttestor(courier, "");
        vm.expectRevert(bytes("zero attestor"));
        registry.registerAttestor(address(0), "x");

        registry.registerAttestor(courier, "Courier API");
        assertTrue(registry.isAttestor(courier));
        registry.removeAttestor(courier);
        assertFalse(registry.isAttestor(courier));
    }

    function test_attest_requiresRegisteredAttestor_andAppendOnly() public {
        bytes32 subject = registry.subjectFor(address(this), 1);

        vm.prank(stranger);
        vm.expectRevert(bytes("not attestor"));
        registry.attest(subject, "fake");

        registry.registerAttestor(courier, "Courier API");
        vm.prank(courier);
        vm.expectRevert(bytes("empty fact"));
        registry.attest(subject, "");

        vm.prank(courier);
        registry.attest(subject, "package delivered and signed for on time");
        vm.prank(courier);
        registry.attest(subject, "no return was ever shipped back");
        assertEq(registry.factCount(subject), 2);

        string memory facts = registry.factsFor(subject);
        assertTrue(_has(facts, "[VERIFIED by Courier API] package delivered and signed for on time"));
        assertTrue(_has(facts, "[VERIFIED by Courier API] no return was ever shipped back"));
    }

    // --- court integration ----------------------------------------------------

    function test_setAttestationRegistry_ownerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("not owner"));
        court.setAttestationRegistry(address(registry));
        court.setAttestationRegistry(address(registry));
        assertEq(address(court.attestationRegistry()), address(registry));
    }

    function test_noRegistry_noVerifiedBlock() public {
        _open("buyer claims non-delivery");
        assertFalse(_has(_prompt(), "AUTHORITATIVE VERIFIED FACTS"));
    }

    function test_registrySet_butNoFacts_noVerifiedBlock() public {
        court.setAttestationRegistry(address(registry));
        _open("buyer claims non-delivery");
        assertFalse(_has(_prompt(), "AUTHORITATIVE VERIFIED FACTS"));
    }

    function test_verifiedFacts_foldIntoPrompt_aboveUntrustedEvidence() public {
        court.setAttestationRegistry(address(registry));
        registry.registerAttestor(courier, "Courier API");
        bytes32 subject = registry.subjectFor(address(this), 1);
        vm.prank(courier);
        registry.attest(subject, "tracking shows delivered to the buyer address");

        _open("buyer claims the item never arrived");
        string memory p = _prompt();

        assertTrue(_has(p, "AUTHORITATIVE VERIFIED FACTS"), "verified block missing");
        assertTrue(_has(p, "tracking shows delivered to the buyer address"), "verified fact text missing");
        // verified facts must appear BEFORE the untrusted evidence fence
        assertTrue(
            _indexOf(p, "AUTHORITATIVE VERIFIED FACTS") < _indexOf(p, "<evidence>"),
            "verified facts must precede untrusted evidence"
        );
        // the party's own claim is still present (as untrusted evidence)
        assertTrue(_has(p, "buyer claims the item never arrived"));
    }
}
