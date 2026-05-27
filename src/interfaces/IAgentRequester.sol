// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Somnia Agents platform interface (verbatim from docs.somnia.network/agents/invoking-agents/from-solidity).
/// Mainnet (5031):  0x5E5205CF39E766118C01636bED000A54D93163E6
/// Testnet (50312): 0x037Bb9C718F3f7fe5eCBDB0b600D607b52706776

enum ConsensusType {
    Majority,
    Threshold
}

enum ResponseStatus {
    None, // 0 - Default zero value (uninitialized storage)
    Pending, // 1 - Awaiting responses
    Success, // 2 - Consensus reached normally
    Failed, // 3 - Validators reported failure
    TimedOut // 4 - Request timed out
}

struct Response {
    address validator;
    bytes result;
    ResponseStatus status;
    uint256 receipt;
    uint256 timestamp;
    uint256 executionCost;
}

struct Request {
    uint256 id;
    address requester;
    address callbackAddress;
    bytes4 callbackSelector;
    address[] subcommittee;
    Response[] responses;
    uint256 responseCount;
    uint256 failureCount;
    uint256 threshold;
    uint256 createdAt;
    uint256 deadline;
    ResponseStatus status;
    ConsensusType consensusType;
    uint256 remainingBudget;
    uint256 perAgentBudget;
}

interface IAgentRequester {
    event RequestCreated(
        uint256 indexed requestId,
        uint256 indexed agentId,
        uint256 perAgentBudget,
        bytes payload,
        address[] subcommittee
    );
    event RequestFinalized(uint256 indexed requestId, ResponseStatus status);

    function createRequest(uint256 agentId, address callbackAddress, bytes4 callbackSelector, bytes calldata payload)
        external
        payable
        returns (uint256 requestId);

    function createAdvancedRequest(
        uint256 agentId,
        address callbackAddress,
        bytes4 callbackSelector,
        bytes calldata payload,
        uint256 subcommitteeSize,
        uint256 threshold,
        ConsensusType consensusType,
        uint256 timeout
    ) external payable returns (uint256 requestId);

    function getRequest(uint256 requestId) external view returns (Request memory);
    function hasRequest(uint256 requestId) external view returns (bool);
    function getRequestDeposit() external view returns (uint256);
    function getAdvancedRequestDeposit(uint256 subcommitteeSize) external view returns (uint256);
}

/// @notice The callback your contract must implement to receive agent responses.
interface IAgentRequesterHandler {
    function handleResponse(
        uint256 requestId,
        Response[] memory responses,
        ResponseStatus status,
        Request memory details
    ) external;
}
