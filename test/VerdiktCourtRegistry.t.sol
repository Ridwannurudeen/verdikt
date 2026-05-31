// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktCourtRegistry} from "../src/VerdiktCourtRegistry.sol";
import {MockAgentRequester} from "./mocks/MockAgentRequester.sol";

contract RevertingQuoteCourt {
    function quoteOpen() external pure returns (uint256) {
        revert("quote unavailable");
    }
}

contract FlakyQuoteCourt {
    bool public shouldRevert;
    uint256 public quote = 1 wei;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function quoteOpen() external view returns (uint256) {
        require(!shouldRevert, "quote unavailable");
        return quote;
    }
}

contract VerdiktCourtRegistryTest is Test {
    MockAgentRequester platform;
    VerdiktCourtRegistry registry;
    VerdiktCourt cheap; // lower perAgentPrice -> lower quoteOpen
    VerdiktCourt pricey; // higher perAgentPrice -> higher quoteOpen

    address opCheap = makeAddr("opCheap");
    address opPricey = makeAddr("opPricey");
    address stranger = makeAddr("stranger");

    function setUp() public {
        platform = new MockAgentRequester();
        registry = new VerdiktCourtRegistry();

        vm.prank(opCheap);
        cheap = new VerdiktCourt(address(platform), 1);
        vm.prank(opCheap);
        cheap.setPerAgentPrice(0.05 ether);

        vm.prank(opPricey);
        pricey = new VerdiktCourt(address(platform), 2);
        vm.prank(opPricey);
        pricey.setPerAgentPrice(0.2 ether);
    }

    function _register() internal {
        vm.prank(opCheap);
        registry.registerCourt(address(cheap), "Cheap Court", "gpt-mini", 3600);
        vm.prank(opPricey);
        registry.registerCourt(address(pricey), "Pricey Court", "gpt-large", 600);
    }

    function test_quotesDiffer() public view {
        assertLt(cheap.quoteOpen(), pricey.quoteOpen());
    }

    function test_register_storesListing() public {
        vm.prank(opCheap);
        uint256 id = registry.registerCourt(address(cheap), "Cheap Court", "gpt-mini", 3600);
        assertEq(id, 0);
        assertEq(registry.courtsCount(), 1);

        VerdiktCourtRegistry.CourtListing memory l = registry.getListing(address(cheap));
        assertEq(l.court, address(cheap));
        assertEq(l.operator, opCheap);
        assertEq(l.name, "Cheap Court");
        assertEq(l.model, "gpt-mini");
        assertEq(l.slaSeconds, 3600);
        assertTrue(l.active);
        assertEq(l.registeredAt, uint64(block.timestamp));
    }

    function test_register_revertsOnZero() public {
        vm.expectRevert(bytes("zero court"));
        registry.registerCourt(address(0), "x", "y", 1);
    }

    function test_register_revertsOnBadCourt() public {
        RevertingQuoteCourt bad = new RevertingQuoteCourt();
        vm.expectRevert(bytes("bad court"));
        registry.registerCourt(address(bad), "bad", "bad", 1);
    }

    function test_register_revertsOnDuplicate() public {
        vm.prank(opCheap);
        registry.registerCourt(address(cheap), "Cheap Court", "gpt-mini", 3600);
        vm.prank(opCheap);
        vm.expectRevert(bytes("already registered"));
        registry.registerCourt(address(cheap), "again", "z", 1);
    }

    function test_listCourts_pagination() public {
        _register();
        assertEq(registry.courtsCount(), 2);

        address[] memory all = registry.listCourts(0, 10);
        assertEq(all.length, 2);
        assertEq(all[0], address(cheap));
        assertEq(all[1], address(pricey));

        address[] memory first = registry.listCourts(0, 1);
        assertEq(first.length, 1);
        assertEq(first[0], address(cheap));

        address[] memory second = registry.listCourts(1, 1);
        assertEq(second.length, 1);
        assertEq(second[0], address(pricey));

        address[] memory beyond = registry.listCourts(5, 10);
        assertEq(beyond.length, 0);
    }

    function test_quoteFor_readsLive() public {
        _register();
        assertEq(registry.quoteFor(address(cheap)), cheap.quoteOpen());
        assertEq(registry.quoteFor(address(pricey)), pricey.quoteOpen());
    }

    function test_cheapest_returnsLowerFee() public {
        _register();
        (address court, uint256 fee) = registry.cheapest();
        assertEq(court, address(cheap));
        assertEq(fee, cheap.quoteOpen());
    }

    function test_cheapest_tracksLiveRepricing() public {
        _register();
        // Operator hikes the cheap court above the pricey one -> winner flips.
        vm.prank(opCheap);
        cheap.setPerAgentPrice(1 ether);
        (address court, uint256 fee) = registry.cheapest();
        assertEq(court, address(pricey));
        assertEq(fee, pricey.quoteOpen());
    }

    function test_cheapest_skipsCourtWhoseQuoteReverts() public {
        FlakyQuoteCourt flaky = new FlakyQuoteCourt();
        vm.prank(opCheap);
        registry.registerCourt(address(cheap), "Cheap Court", "gpt-mini", 3600);
        registry.registerCourt(address(flaky), "Flaky Court", "broken", 1);

        flaky.setShouldRevert(true);

        (address court, uint256 fee) = registry.cheapest();
        assertEq(court, address(cheap));
        assertEq(fee, cheap.quoteOpen());
    }

    function test_setActive_removesFromCheapest() public {
        _register();
        vm.prank(opCheap);
        registry.setActive(address(cheap), false);

        (address court, uint256 fee) = registry.cheapest();
        assertEq(court, address(pricey));
        assertEq(fee, pricey.quoteOpen());

        VerdiktCourtRegistry.CourtListing memory l = registry.getListing(address(cheap));
        assertFalse(l.active);
    }

    function test_cheapest_revertsWhenNoneActive() public {
        _register();
        vm.prank(opCheap);
        registry.setActive(address(cheap), false);
        vm.prank(opPricey);
        registry.setActive(address(pricey), false);

        vm.expectRevert(bytes("no active courts"));
        registry.cheapest();
    }

    function test_setActive_onlyOperator() public {
        _register();
        vm.prank(stranger);
        vm.expectRevert(bytes("not operator"));
        registry.setActive(address(cheap), false);
    }

    function test_updateListing_onlyOperator() public {
        _register();
        vm.prank(stranger);
        vm.expectRevert(bytes("not operator"));
        registry.updateListing(address(cheap), "hijack", "evil", 1);
    }

    function test_updateListing_mutates() public {
        _register();
        vm.prank(opCheap);
        registry.updateListing(address(cheap), "Renamed", "gpt-turbo", 7200);

        VerdiktCourtRegistry.CourtListing memory l = registry.getListing(address(cheap));
        assertEq(l.name, "Renamed");
        assertEq(l.model, "gpt-turbo");
        assertEq(l.slaSeconds, 7200);
    }

    function test_setActive_reactivates() public {
        _register();
        vm.prank(opCheap);
        registry.setActive(address(cheap), false);
        vm.prank(opCheap);
        registry.setActive(address(cheap), true);
        assertTrue(registry.getListing(address(cheap)).active);
    }

    function test_mutate_revertsWhenNotRegistered() public {
        vm.prank(opCheap);
        vm.expectRevert(bytes("not registered"));
        registry.setActive(address(cheap), false);
    }
}
