// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktTimelock} from "../src/VerdiktTimelock.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract VerdiktTimelockTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;
    VerdiktTimelock timelock;

    address admin = address(0xA11CE);
    uint256 delay = 1 days;

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
        timelock = new VerdiktTimelock(admin, delay);

        // Migrate Court ownership to the timelock: court owner starts the transfer,
        // then the timelock accepts it via a queued call.
        court.transferOwnership(address(timelock));

        bytes memory acceptData = abi.encodeWithSelector(VerdiktCourt.acceptOwnership.selector);
        uint256 eta = block.timestamp + delay;
        vm.prank(admin);
        timelock.queue(address(court), 0, acceptData, eta);
        vm.warp(eta);
        vm.prank(admin);
        timelock.execute(address(court), 0, acceptData, eta);

        assertEq(court.owner(), address(timelock));
    }

    function test_setUp_ownershipMigrated() public view {
        assertEq(court.owner(), address(timelock));
        assertEq(court.pendingOwner(), address(0));
    }

    function test_queueExecute_changesAppealWindow() public {
        uint64 newWindow = 2 hours;
        bytes memory data = abi.encodeWithSelector(VerdiktCourt.setAppealWindow.selector, newWindow);
        uint256 eta = block.timestamp + delay;

        vm.prank(admin);
        timelock.queue(address(court), 0, data, eta);

        // Executing before eta reverts.
        vm.prank(admin);
        vm.expectRevert(bytes("not ready"));
        timelock.execute(address(court), 0, data, eta);

        vm.warp(eta);
        vm.prank(admin);
        timelock.execute(address(court), 0, data, eta);

        assertEq(court.appealWindow(), newWindow);
    }

    function test_queue_revertsForNonAdmin() public {
        bytes memory data = abi.encodeWithSelector(VerdiktCourt.setAppealWindow.selector, uint64(2 hours));
        uint256 eta = block.timestamp + delay;
        vm.expectRevert(bytes("not admin"));
        timelock.queue(address(court), 0, data, eta);
    }

    function test_queue_revertsEtaTooSoon() public {
        bytes memory data = abi.encodeWithSelector(VerdiktCourt.setAppealWindow.selector, uint64(2 hours));
        uint256 eta = block.timestamp + delay - 1;
        vm.prank(admin);
        vm.expectRevert(bytes("eta too soon"));
        timelock.queue(address(court), 0, data, eta);
    }

    function test_cancel_preventsExecute() public {
        bytes memory data = abi.encodeWithSelector(VerdiktCourt.setAppealWindow.selector, uint64(2 hours));
        uint256 eta = block.timestamp + delay;

        vm.prank(admin);
        bytes32 txHash = timelock.queue(address(court), 0, data, eta);

        vm.prank(admin);
        timelock.cancel(txHash);

        vm.warp(eta);
        vm.prank(admin);
        vm.expectRevert(bytes("not queued"));
        timelock.execute(address(court), 0, data, eta);
    }

    function test_execute_revertsForNonAdmin() public {
        bytes memory data = abi.encodeWithSelector(VerdiktCourt.setAppealWindow.selector, uint64(2 hours));
        uint256 eta = block.timestamp + delay;
        vm.prank(admin);
        timelock.queue(address(court), 0, data, eta);
        vm.warp(eta);
        vm.expectRevert(bytes("not admin"));
        timelock.execute(address(court), 0, data, eta);
    }

    function test_constructor_revertsDelayTooLow() public {
        uint256 tooLow = timelock.MIN_DELAY() - 1;
        vm.expectRevert(bytes("delay too low"));
        new VerdiktTimelock(admin, tooLow);
    }

    function test_constructor_revertsDelayTooHigh() public {
        uint256 tooHigh = timelock.MAX_DELAY() + 1;
        vm.expectRevert(bytes("delay too high"));
        new VerdiktTimelock(admin, tooHigh);
    }
}

contract VerdiktCourtOwnershipTest is Test {
    MockAgentRequester platform;
    VerdiktCourt court;

    address newOwner = address(0xB0B);

    function setUp() public {
        platform = new MockAgentRequester();
        court = new VerdiktCourt(address(platform), 1);
    }

    function test_transferAndAccept() public {
        court.transferOwnership(newOwner);
        assertEq(court.pendingOwner(), newOwner);
        assertEq(court.owner(), address(this));

        vm.prank(newOwner);
        court.acceptOwnership();
        assertEq(court.owner(), newOwner);
        assertEq(court.pendingOwner(), address(0));
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(newOwner);
        vm.expectRevert(bytes("not owner"));
        court.transferOwnership(newOwner);
    }

    function test_acceptOwnership_revertsForNonPending() public {
        court.transferOwnership(newOwner);
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("not pending owner"));
        court.acceptOwnership();
    }
}
