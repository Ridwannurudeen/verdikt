// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IAgentRequester, Response, Request, ConsensusType, ResponseStatus} from "../src/interfaces/IAgentRequester.sol";
import {ILLMAgent} from "../src/interfaces/ILLMAgent.sol";

/// @title DeterminismProbe
/// @notice Week-1 gate: fire one LLM-inference panel with a fixed prompt + allowedValues
/// and record EVERY validator's raw verdict, so we can measure whether the panel converges
/// (the premise the whole AI-jury design rests on). Uses Threshold consensus with
/// threshold == panel so the platform collects all responses for inspection.
contract DeterminismProbe {
    IAgentRequester public immutable platform;
    uint256 public agentId;
    uint256 public lastRequestId;
    uint8 public lastStatus;
    string[] public results;

    event Probed(uint256 requestId, uint256 panel);
    event ProbeResult(uint256 requestId, uint8 status, uint256 resultCount);

    constructor(address platform_, uint256 agentId_) {
        platform = IAgentRequester(platform_);
        agentId = agentId_;
    }

    function fire(string calldata evidence, uint256 panel) external payable returns (uint256 requestId) {
        string[] memory allowed = new string[](3);
        allowed[0] = "PAYEE";
        allowed[1] = "PAYER";
        allowed[2] = "SPLIT";
        string memory prompt = string.concat(
            "Escrow dispute. Review the evidence and decide who is right.\n\nEVIDENCE:\n",
            evidence,
            "\n\nRespond with exactly one of: PAYEE, PAYER, or SPLIT."
        );
        bytes memory payload = abi.encodeWithSelector(
            ILLMAgent.inferString.selector,
            prompt,
            "You are an impartial on-chain arbitrator. Output only the verdict label.",
            true,
            allowed
        );

        requestId = platform.createAdvancedRequest{value: msg.value}(
            agentId,
            address(this),
            this.handleResponse.selector,
            payload,
            panel,
            panel, // threshold == panel: wait for all, so we can inspect divergence
            ConsensusType.Threshold,
            300
        );
        lastRequestId = requestId;
        emit Probed(requestId, panel);
    }

    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory /*details*/
    )
        external
    {
        require(msg.sender == address(platform), "only platform");
        delete results;
        for (uint256 i = 0; i < responses.length; i++) {
            if (responses[i].result.length > 0) {
                results.push(abi.decode(responses[i].result, (string)));
            }
        }
        lastStatus = uint8(status);
        emit ProbeResult(requestId, uint8(status), results.length);
    }

    function getResults() external view returns (string[] memory) {
        return results;
    }

    receive() external payable {}
}

/// @notice Deploys the probe. Then fire it with cast and read getResults() after ~30s.
/// forge script script/Probe.s.sol:ProbeDeploy --rpc-url shannon --broadcast
contract ProbeDeploy is Script {
    address constant DEFAULT_PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address platform = vm.envOr("SOMNIA_PLATFORM", DEFAULT_PLATFORM);
        uint256 agentId = vm.envUint("LLM_AGENT_ID");

        vm.startBroadcast(pk);
        DeterminismProbe probe = new DeterminismProbe(platform, agentId);
        vm.stopBroadcast();

        console.log("DeterminismProbe:", address(probe));
        console.log("Next: cd script && npm install && node run-determinism-gate.mjs", address(probe));
    }
}

/// @title GradedDeterminismProbe
/// @notice Same gate as DeterminismProbe, but offers the 5-label GRADED set
/// (PAYER/SPLIT25/SPLIT50/SPLIT75/PAYEE) with the exact prompt VerdiktCourt._buildPayload
/// emits in graded mode — so the histogram measures whether a panel converges byte-identically
/// on the wider, graded answer space (the open question gating graded SPLIT %). Threshold
/// consensus with threshold == panel so every validator's raw label is collected.
contract GradedDeterminismProbe {
    IAgentRequester public immutable platform;
    uint256 public agentId;
    uint256 public lastRequestId;
    uint8 public lastStatus;
    string[] public results;

    string internal constant SYSTEM_PROMPT =
        "You are an impartial on-chain arbitrator resolving an escrow dispute. Decide strictly from the evidence provided. Output only the verdict label.";

    event Probed(uint256 requestId, uint256 panel);
    event ProbeResult(uint256 requestId, uint8 status, uint256 resultCount);

    constructor(address platform_, uint256 agentId_) {
        platform = IAgentRequester(platform_);
        agentId = agentId_;
    }

    function fire(string calldata evidence, uint256 panel) external payable returns (uint256 requestId) {
        string[] memory allowed = new string[](5);
        allowed[0] = "PAYER";
        allowed[1] = "SPLIT25";
        allowed[2] = "SPLIT50";
        allowed[3] = "SPLIT75";
        allowed[4] = "PAYEE";
        string memory prompt = string.concat(
            "Escrow dispute. Review the evidence and decide how to apportion the funds between the payer (buyer) and payee (seller).\n\nEVIDENCE:\n",
            evidence,
            "\n\nRespond with exactly one label for the payee's share: PAYER (payee gets 0%, full refund to buyer), SPLIT25 (payee 25%), SPLIT50 (payee 50%), SPLIT75 (payee 75%), or PAYEE (payee 100%)."
        );
        bytes memory payload =
            abi.encodeWithSelector(ILLMAgent.inferString.selector, prompt, SYSTEM_PROMPT, true, allowed);

        requestId = platform.createAdvancedRequest{value: msg.value}(
            agentId,
            address(this),
            this.handleResponse.selector,
            payload,
            panel,
            panel, // threshold == panel: collect all, inspect divergence
            ConsensusType.Threshold,
            300
        );
        lastRequestId = requestId;
        emit Probed(requestId, panel);
    }

    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory /*details*/
    )
        external
    {
        require(msg.sender == address(platform), "only platform");
        delete results;
        for (uint256 i = 0; i < responses.length; i++) {
            if (responses[i].result.length > 0) {
                results.push(abi.decode(responses[i].result, (string)));
            }
        }
        lastStatus = uint8(status);
        emit ProbeResult(requestId, uint8(status), results.length);
    }

    function getResults() external view returns (string[] memory) {
        return results;
    }

    receive() external payable {}
}

/// @notice Deploys the graded probe. Drive it with the same runner:
/// forge script script/Probe.s.sol:GradedProbeDeploy --rpc-url shannon --broadcast
contract GradedProbeDeploy is Script {
    address constant DEFAULT_PLATFORM = 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address platform = vm.envOr("SOMNIA_PLATFORM", DEFAULT_PLATFORM);
        uint256 agentId = vm.envUint("LLM_AGENT_ID");

        vm.startBroadcast(pk);
        GradedDeterminismProbe probe = new GradedDeterminismProbe(platform, agentId);
        vm.stopBroadcast();

        console.log("GradedDeterminismProbe:", address(probe));
        console.log("Next: cd script && node run-determinism-gate.mjs", address(probe));
    }
}
