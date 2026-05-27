// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Method signatures for Somnia's LLM Inference base agent.
/// Used only with abi.encodeWithSelector(...) to build the request payload — the agent
/// is invoked through IAgentRequester, not called directly.
/// Source: docs.somnia.network/agents/base-agents/llm-inference
interface ILLMAgent {
    /// @param allowedValues constrains the model to return exactly one of these strings.
    ///        This is what makes Majority consensus (byte-identical results) reliable.
    function inferString(
        string calldata prompt,
        string calldata system,
        bool chainOfThought,
        string[] calldata allowedValues
    ) external returns (string memory response);

    function inferNumber(
        string calldata prompt,
        string calldata system,
        int256 minValue,
        int256 maxValue,
        bool chainOfThought
    ) external returns (int256 response);
}
