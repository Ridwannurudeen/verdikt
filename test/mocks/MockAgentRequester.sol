// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IAgentRequester,
    Response,
    Request,
    ConsensusType,
    ResponseStatus
} from "../../src/interfaces/IAgentRequester.sol";

/// @notice Test double for the Somnia Agents platform. Records requests and lets a test
/// drive the consensus callback (mimicking a Majority panel of byte-identical results).
contract MockAgentRequester is IAgentRequester {
    uint256 public constant MIN_PER_AGENT_DEPOSIT = 0.01 ether;
    uint256 public constant DEFAULT_SUB_SIZE = 3;

    struct Stored {
        uint256 agentId;
        address callbackAddress;
        bytes4 callbackSelector;
        bytes payload;
        uint256 subcommitteeSize;
        uint256 threshold;
        ConsensusType consensusType;
        bool exists;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Stored) public requests;

    function createRequest(uint256 agentId, address callbackAddress, bytes4 callbackSelector, bytes calldata payload)
        external
        payable
        returns (uint256 requestId)
    {
        requestId =
            _store(agentId, callbackAddress, callbackSelector, payload, DEFAULT_SUB_SIZE, 2, ConsensusType.Majority);
    }

    function createAdvancedRequest(
        uint256 agentId,
        address callbackAddress,
        bytes4 callbackSelector,
        bytes calldata payload,
        uint256 subcommitteeSize,
        uint256 threshold,
        ConsensusType consensusType,
        uint256 /*timeout*/
    ) external payable returns (uint256 requestId) {
        requestId =
            _store(agentId, callbackAddress, callbackSelector, payload, subcommitteeSize, threshold, consensusType);
    }

    function _store(
        uint256 agentId,
        address cb,
        bytes4 sel,
        bytes calldata payload,
        uint256 subSize,
        uint256 threshold,
        ConsensusType ct
    ) internal returns (uint256 requestId) {
        requestId = nextId++;
        requests[requestId] = Stored(agentId, cb, sel, payload, subSize, threshold, ct, true);
    }

    // --- test drivers ---------------------------------------------------------

    /// @notice Deliver a successful Majority verdict: `threshold` byte-identical results.
    function fireSuccess(uint256 requestId, string memory verdict) external {
        Stored memory s = requests[requestId];
        require(s.exists, "no request");
        uint256 n = s.threshold;
        Response[] memory responses = new Response[](n);
        for (uint256 i = 0; i < n; i++) {
            responses[i] = Response({
                validator: address(uint160(0x1000 + i)),
                result: abi.encode(verdict),
                status: ResponseStatus.Success,
                receipt: requestId * 1000 + i,
                timestamp: block.timestamp,
                executionCost: 0
            });
        }
        _callback(requestId, s, responses, ResponseStatus.Success);
    }

    /// @notice Deliver a non-success terminal status (Failed / TimedOut) with no responses.
    function fireStatus(uint256 requestId, ResponseStatus status) external {
        Stored memory s = requests[requestId];
        require(s.exists, "no request");
        Response[] memory responses = new Response[](0);
        _callback(requestId, s, responses, status);
    }

    function _callback(uint256 requestId, Stored memory s, Response[] memory responses, ResponseStatus status)
        internal
    {
        Request memory details;
        details.id = requestId;
        details.requester = address(this);
        details.callbackAddress = s.callbackAddress;
        details.callbackSelector = s.callbackSelector;
        details.subcommittee = new address[](0);
        details.responses = responses;
        details.responseCount = responses.length;
        details.threshold = s.threshold;
        details.status = status;
        details.consensusType = s.consensusType;

        (bool ok, bytes memory ret) =
            s.callbackAddress.call(abi.encodeWithSelector(s.callbackSelector, requestId, responses, status, details));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // --- IAgentRequester views ------------------------------------------------

    function getRequest(uint256 requestId) external view returns (Request memory details) {
        Stored memory s = requests[requestId];
        details.id = requestId;
        details.threshold = s.threshold;
        details.consensusType = s.consensusType;
        details.callbackAddress = s.callbackAddress;
    }

    function hasRequest(uint256 requestId) external view returns (bool) {
        return requests[requestId].exists;
    }

    function getRequestDeposit() external pure returns (uint256) {
        return MIN_PER_AGENT_DEPOSIT * DEFAULT_SUB_SIZE;
    }

    function getAdvancedRequestDeposit(uint256 subcommitteeSize) external pure returns (uint256) {
        return MIN_PER_AGENT_DEPOSIT * subcommitteeSize;
    }
}
