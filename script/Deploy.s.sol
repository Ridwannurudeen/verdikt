// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VerdiktCourt} from "../src/VerdiktCourt.sol";
import {VerdiktEscrow} from "../src/VerdiktEscrow.sol";

/// @notice Deploys VerdiktCourt + VerdiktEscrow to Somnia.
/// Required env: PRIVATE_KEY, LLM_AGENT_ID. Optional: SOMNIA_PLATFORM, TREASURY.
/// Usage: forge script script/Deploy.s.sol --rpc-url shannon --broadcast
contract Deploy is Script {
    // Somnia Agents platform (testnet Shannon, chain 50312)
    address constant DEFAULT_PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address platform = vm.envOr("SOMNIA_PLATFORM", DEFAULT_PLATFORM);
        uint256 agentId = vm.envUint("LLM_AGENT_ID");
        address treasury = vm.envOr("TREASURY", vm.addr(pk));

        vm.startBroadcast(pk);
        VerdiktCourt court = new VerdiktCourt(platform, agentId);
        VerdiktEscrow escrow = new VerdiktEscrow(address(court), treasury);
        vm.stopBroadcast();

        console.log("Platform     :", platform);
        console.log("LLM agent id :", agentId);
        console.log("VerdiktCourt :", address(court));
        console.log("VerdiktEscrow:", address(escrow));
    }
}
