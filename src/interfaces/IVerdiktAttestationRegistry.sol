// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The Court's view of the attestation registry: read the verified facts for a subject
/// (a dispute's consumer + escrow reference) to fold into the panel prompt as authoritative.
interface IVerdiktAttestationRegistry {
    function subjectFor(address consumer, uint256 escrowRef) external pure returns (bytes32);
    function factsFor(bytes32 subject) external view returns (string memory);
}
