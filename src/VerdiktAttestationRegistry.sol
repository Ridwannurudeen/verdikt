// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktAttestationRegistry} from "./interfaces/IVerdiktAttestationRegistry.sol";

/// @title VerdiktAttestationRegistry
/// @notice A governed registry of trusted attestors (oracles, courier APIs, EAS bridges, price
/// feeds) that post VERIFIED facts about a dispute subject. VerdiktCourt folds these facts into the
/// panel prompt as AUTHORITATIVE — so a verdict rests on attested truth, not only the parties'
/// (untrusted) claims. Facts are append-only per subject and rendered deterministically so panel
/// consensus stays byte-identical.
contract VerdiktAttestationRegistry is IVerdiktAttestationRegistry {
    address public owner;

    /// @notice An attestor is registered iff its label is non-empty.
    mapping(address => string) public attestorLabel;
    /// @dev rendered, append-only facts per subject.
    mapping(bytes32 => string) private _facts;
    mapping(bytes32 => uint256) public factCount;

    event AttestorRegistered(address indexed attestor, string label);
    event AttestorRemoved(address indexed attestor);
    event Attested(bytes32 indexed subject, address indexed attestor, string fact);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice The subject key for a dispute = its consumer + escrow reference. Attestors compute
    /// this from the public CaseOpened event; the Court reads facts under the same key.
    function subjectFor(address consumer, uint256 escrowRef) public pure returns (bytes32) {
        return keccak256(abi.encode(consumer, escrowRef));
    }

    function isAttestor(address a) public view returns (bool) {
        return bytes(attestorLabel[a]).length > 0;
    }

    // --- governance -----------------------------------------------------------

    function registerAttestor(address attestor, string calldata label) external onlyOwner {
        require(attestor != address(0), "zero attestor");
        require(bytes(label).length > 0, "empty label");
        attestorLabel[attestor] = label;
        emit AttestorRegistered(attestor, label);
    }

    function removeAttestor(address attestor) external onlyOwner {
        delete attestorLabel[attestor];
        emit AttestorRemoved(attestor);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --- attestation ----------------------------------------------------------

    /// @notice A registered attestor posts a verified fact about a subject (append-only). The
    /// attestor's own transaction is the signature; the label identifies the source to the panel.
    function attest(bytes32 subject, string calldata fact) external {
        require(isAttestor(msg.sender), "not attestor");
        require(bytes(fact).length > 0, "empty fact");
        _facts[subject] = string.concat(_facts[subject], "[VERIFIED by ", attestorLabel[msg.sender], "] ", fact, "\n");
        factCount[subject] += 1;
        emit Attested(subject, msg.sender, fact);
    }

    function factsFor(bytes32 subject) external view override returns (string memory) {
        return _facts[subject];
    }
}
