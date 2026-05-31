// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EvidenceLib} from "../src/lib/EvidenceLib.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";
import {Verdict} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract EvidenceLibTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktEscrow escrow;

    address payer = makeAddr("payer");
    address payee = makeAddr("payee");
    address treasury = makeAddr("treasury");

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        escrow = new VerdiktEscrow(address(court), treasury);
        vm.deal(payer, 100 ether);
        vm.deal(payee, 100 ether);
    }

    function _sample() internal view returns (EvidenceLib.Evidence memory) {
        return EvidenceLib.Evidence({
            dealId: 7,
            payer: payer,
            payee: payee,
            amount: 1 ether,
            deliverBy: uint64(block.timestamp + 1 days),
            observedAt: uint64(block.timestamp),
            claim: "goods marked delivered but never arrived",
            priorCaseId: 0
        });
    }

    function test_format_isDeterministic() public view {
        string memory a = EvidenceLib.format(_sample());
        string memory b = EvidenceLib.format(_sample());
        assertEq(keccak256(bytes(a)), keccak256(bytes(b)));
    }

    function test_format_exactString() public {
        EvidenceLib.Evidence memory e = EvidenceLib.Evidence({
            dealId: 7,
            payer: address(0xA1),
            payee: address(0xB2),
            amount: 1000000000000000000,
            deliverBy: 1735689600,
            observedAt: 1735693200,
            claim: "goods marked delivered but never arrived",
            priorCaseId: 0
        });
        string memory expected = "dealId=7\n" "payer=0x00000000000000000000000000000000000000a1\n"
            "payee=0x00000000000000000000000000000000000000b2\n" "amount=1000000000000000000\n" "deliverBy=1735689600\n"
            "observedAt=1735693200\n" "priorCaseId=none\n" "claim=goods marked delivered but never arrived";
        assertEq(EvidenceLib.format(e), expected);
    }

    function test_format_priorCaseIdCited() public pure {
        EvidenceLib.Evidence memory e = EvidenceLib.Evidence({
            dealId: 1,
            payer: address(0),
            payee: address(0),
            amount: 0,
            deliverBy: 0,
            observedAt: 0,
            claim: "x",
            priorCaseId: 42
        });
        string memory s = EvidenceLib.format(e);
        assertTrue(_contains(s, "priorCaseId=42"));
    }

    function test_format_differentFieldsDiffer() public view {
        EvidenceLib.Evidence memory a = _sample();
        EvidenceLib.Evidence memory b = _sample();
        b.amount = 2 ether;
        assertTrue(keccak256(bytes(EvidenceLib.format(a))) != keccak256(bytes(EvidenceLib.format(b))));

        EvidenceLib.Evidence memory c = _sample();
        c.claim = "different claim";
        assertTrue(keccak256(bytes(EvidenceLib.format(a))) != keccak256(bytes(EvidenceLib.format(c))));

        EvidenceLib.Evidence memory d = _sample();
        d.priorCaseId = 5;
        assertTrue(keccak256(bytes(EvidenceLib.format(a))) != keccak256(bytes(EvidenceLib.format(d))));
    }

    function test_endToEnd_structuredEvidenceSettles() public {
        vm.prank(payer);
        uint256 dealId = escrow.createDeal{value: 1 ether}(payee, uint64(block.timestamp + 1 days));

        (address dPayer, address dPayee, uint256 dAmount,, uint64 dDeliverBy,) = escrow.deals(dealId);
        EvidenceLib.Evidence memory e = EvidenceLib.Evidence({
            dealId: dealId,
            payer: dPayer,
            payee: dPayee,
            amount: dAmount,
            deliverBy: dDeliverBy,
            observedAt: uint64(block.timestamp),
            claim: "never received anything",
            priorCaseId: 0
        });
        string memory ev = EvidenceLib.format(e);

        uint256 fee = court.quoteOpen();
        vm.prank(payer);
        escrow.dispute{value: fee}(dealId, ev);

        uint256 reqId = platform.nextId() - 1;
        platform.fireSuccess(reqId, "PAYER");

        (,,,,, uint256 caseId) = escrow.deals(dealId);
        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        assertEq(escrow.pending(payer), 1 ether);

        uint256 before = payer.balance;
        vm.prank(payer);
        escrow.withdraw();
        assertEq(payer.balance, before + 1 ether);

        (,,, VerdiktEscrow.DealStatus st,,) = escrow.deals(dealId);
        assertEq(uint8(st), uint8(VerdiktEscrow.DealStatus.Settled));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
