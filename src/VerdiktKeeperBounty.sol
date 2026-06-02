// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, CaseView, CaseStatus} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktKeeperBounty
/// @notice Decentralizes settlement: `finalize` is already permissionless, this adds the incentive.
/// Anyone funds a bounty to get a case finalized; any keeper calls `finalizeAndClaim` to settle it (or
/// just claim if someone already did) and take the pot. No trust, no whitelist, no Court change — a
/// permissionless market for liveness. Funders can `reclaim` their contribution any time before the
/// bounty is claimed.
contract VerdiktKeeperBounty {
    mapping(bytes32 => uint256) public pot; // key(court,caseId) => total bounty
    mapping(bytes32 => mapping(address => uint256)) public contributed;
    mapping(bytes32 => bool) public claimed;

    event BountyFunded(
        address indexed court, uint256 indexed caseId, address indexed funder, uint256 amount, uint256 pot
    );
    event BountyReclaimed(address indexed court, uint256 indexed caseId, address indexed funder, uint256 amount);
    event BountyClaimed(address indexed court, uint256 indexed caseId, address indexed keeper, uint256 amount);

    function key(address court, uint256 caseId) public pure returns (bytes32) {
        return keccak256(abi.encode(court, caseId));
    }

    /// @notice Add to the bounty for finalizing (court, caseId).
    function fundBounty(address court, uint256 caseId) external payable {
        require(msg.value > 0, "no value");
        bytes32 k = key(court, caseId);
        require(!claimed[k], "already claimed");
        pot[k] += msg.value;
        contributed[k][msg.sender] += msg.value;
        emit BountyFunded(court, caseId, msg.sender, msg.value, pot[k]);
    }

    /// @notice Take your contribution back while the bounty is still unclaimed.
    function reclaim(address court, uint256 caseId) external {
        bytes32 k = key(court, caseId);
        require(!claimed[k], "already claimed");
        uint256 amount = contributed[k][msg.sender];
        require(amount > 0, "nothing");
        contributed[k][msg.sender] = 0;
        pot[k] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "refund failed");
        emit BountyReclaimed(court, caseId, msg.sender, amount);
    }

    /// @notice Finalize the case if it isn't already, then take the bounty. Reverts if the case isn't
    /// finalizable yet (e.g. the appeal window is still open).
    function finalizeAndClaim(address court, uint256 caseId) external {
        bytes32 k = key(court, caseId);
        uint256 amount = pot[k];
        require(amount > 0 && !claimed[k], "no bounty");
        CaseView memory c = IVerdiktCourt(court).getCase(caseId);
        if (c.status != CaseStatus.Final) {
            IVerdiktCourt(court).finalize(caseId);
        }
        claimed[k] = true;
        pot[k] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay failed");
        emit BountyClaimed(court, caseId, msg.sender, amount);
    }
}
