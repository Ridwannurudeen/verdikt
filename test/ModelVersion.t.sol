// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {IVerdiktConsumer, Verdict, CaseStatus} from "../src/interfaces/IVerdiktCourt.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

/// @notice The inference model/agent id is snapshotted per case at open time and dispatch uses the
/// snapshot, so a finalized verdict is auditable against the exact model that produced it and a later
/// setAgentId change cannot silently reinterpret past or in-flight cases.
contract ModelVersionTest is Test, IVerdiktConsumer {
    MockAgentRequester platform;
    VerdiktCourt court;
    Verdict public lastVerdict;

    function onVerdict(uint256, Verdict v) external override {
        lastVerdict = v;
    }

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {}

    function _open(string memory ev) internal returns (uint256 caseId) {
        caseId = court.openCase{value: court.quoteOpen()}(1, ev);
    }

    function _dispatchedAgentId() internal view returns (uint256 agentId) {
        (agentId,,,,,,,) = platform.requests(platform.nextId() - 1);
    }

    function test_openCase_snapshotsCurrentAgentId() public {
        uint256 caseId = _open("a");
        assertEq(court.modelOf(caseId), 1);
        assertEq(_dispatchedAgentId(), 1);
    }

    function test_setAgentId_onlyAffectsNewCases() public {
        uint256 c1 = _open("a");
        assertEq(court.modelOf(c1), 1);

        court.setAgentId(2);
        assertEq(court.agentId(), 2);

        uint256 c2 = _open("b");
        assertEq(court.modelOf(c2), 2);
        assertEq(_dispatchedAgentId(), 2);
        // the earlier case stays on the model in force when it opened
        assertEq(court.modelOf(c1), 1);
    }

    function test_setAgentId_onlyOwner() public {
        vm.prank(makeAddr("gov"));
        vm.expectRevert(bytes("not owner"));
        court.setAgentId(2);
    }

    function test_setAgentId_rejectsZero() public {
        vm.expectRevert(bytes("zero agent"));
        court.setAgentId(0);
    }

    function test_resolvesEndToEnd_withSnapshottedModel() public {
        court.setAgentId(7);
        uint256 caseId = _open("evidence");
        assertEq(court.modelOf(caseId), 7);
        assertEq(_dispatchedAgentId(), 7);

        platform.fireSuccess(platform.nextId() - 1, "PAYEE");
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Ruled));

        // a later model change does not retroactively alter the resolved case
        court.setAgentId(9);
        assertEq(court.modelOf(caseId), 7);

        vm.warp(block.timestamp + court.appealWindow() + 1);
        court.finalize(caseId);
        assertEq(uint8(court.getCase(caseId).status), uint8(CaseStatus.Final));
        assertEq(uint8(court.getCase(caseId).verdict), uint8(Verdict.PAYEE));
    }
}
