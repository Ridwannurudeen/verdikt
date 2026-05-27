// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VerdiktInsurance} from "../src/VerdiktInsurance.sol";

/// @notice Deploys VerdiktInsurance against an already-deployed VerdiktCourt.
/// Required env: PRIVATE_KEY, COURT_ADDRESS. Optional: TREASURY.
/// Usage: forge script script/DeployInsurance.s.sol --rpc-url shannon --broadcast
contract DeployInsurance is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address courtAddr = vm.envAddress("COURT_ADDRESS");
        address treasury = vm.envOr("TREASURY", vm.addr(pk));

        vm.startBroadcast(pk);
        VerdiktInsurance insurance = new VerdiktInsurance(courtAddr, treasury);
        vm.stopBroadcast();

        console.log("VerdiktCourt    :", courtAddr);
        console.log("Treasury        :", treasury);
        console.log("VerdiktInsurance:", address(insurance));
    }
}
