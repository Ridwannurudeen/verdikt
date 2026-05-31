// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, Verdict, CaseStatus, CaseView} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktRegistry
/// @notice An on-chain, queryable index of finalized rulings — machine-generated case law.
/// Permissionless and append-only: anyone (keeper/agent) may record a court case once it is
/// FINAL, after which the ruling is immutable. This is the precedent layer that
/// EvidenceLib.priorCaseId points at — a later panel/agent can look up a cited prior
/// caseId's verdict here.
contract VerdiktRegistry {
    IVerdiktCourt public immutable court;

    struct Ruling {
        uint256 caseId;
        address consumer;
        uint256 escrowRef;
        Verdict verdict;
        uint256 receiptId;
        uint64 rulingTime;
        bytes32 topic;
    }

    mapping(uint256 => Ruling) private rulings;
    mapping(uint256 => bool) public recorded;

    uint256[] private all;
    mapping(bytes32 => uint256[]) private byTopic;
    mapping(address => uint256[]) private byConsumer;

    event RulingRecorded(
        uint256 indexed caseId, address indexed consumer, Verdict verdict, bytes32 indexed topic, uint256 receiptId
    );

    constructor(address court_) {
        court = IVerdiktCourt(court_);
    }

    /// @notice Record a FINAL court case into the precedent index. Permissionless.
    function record(uint256 caseId, bytes32 topic) external {
        require(!recorded[caseId], "already recorded");
        CaseView memory cv = court.getCase(caseId);
        require(cv.status == CaseStatus.Final, "not final");

        rulings[caseId] = Ruling({
            caseId: caseId,
            consumer: cv.consumer,
            escrowRef: cv.escrowRef,
            verdict: cv.verdict,
            receiptId: cv.receiptId,
            rulingTime: cv.rulingTime,
            topic: topic
        });
        recorded[caseId] = true;
        all.push(caseId);
        byTopic[topic].push(caseId);
        byConsumer[cv.consumer].push(caseId);

        emit RulingRecorded(caseId, cv.consumer, cv.verdict, topic, cv.receiptId);
    }

    // --- views ----------------------------------------------------------------

    function getRuling(uint256 caseId) external view returns (Ruling memory) {
        return rulings[caseId];
    }

    function rulingsCount() external view returns (uint256) {
        return all.length;
    }

    /// @notice Paginated list of recorded caseIds in insertion order.
    function allRulings(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256 total = all.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256[] memory page = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = all[i];
        }
        return page;
    }

    function rulingsByTopic(bytes32 topic) external view returns (uint256[] memory) {
        return byTopic[topic];
    }

    function rulingsByConsumer(address consumer) external view returns (uint256[] memory) {
        return byConsumer[consumer];
    }

    function isRecorded(uint256 caseId) external view returns (bool) {
        return recorded[caseId];
    }
}
