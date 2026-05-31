// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, Verdict, CaseStatus, CaseView} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktReputation
/// @notice A portable, receipt-backed litigation record per party. An address's behavior
/// across VerdiktCourt disputes becomes a credential: wins, losses, and splits accumulate
/// into a reputation that any contract can read.
///
/// @dev Trust assumption: `CaseView` exposes only the consuming contract and its escrow
/// reference, not the disputing parties. So the caller asserts which party fought and which
/// `side` of the dispute they were on; the VERDICT, however, is read authoritatively from the
/// court — win/loss is never caller-controlled. A production version would source the parties
/// directly from the consumer (e.g. VerdiktEscrow's deal) to remove the `side` assertion; here
/// we keep it minimal. The double-count guard prevents one case from inflating a tally.
contract VerdiktReputation {
    IVerdiktCourt public immutable court;

    /// @notice Which side of the dispute a party was on.
    enum Side {
        Payee,
        Payer
    }

    struct Rep {
        uint256 disputes;
        uint256 wins;
        uint256 losses;
        uint256 splits;
        uint256 lastCaseId;
    }

    mapping(address => Rep) private reps;
    /// @notice (caseId => party => recorded) double-count guard.
    mapping(uint256 => mapping(address => bool)) public recorded;

    event ReputationRecorded(address indexed party, uint256 indexed caseId, Side side, Verdict verdict);

    constructor(address court_) {
        court = IVerdiktCourt(court_);
    }

    /// @notice Record a finalized case's outcome against a party. Permissionless.
    /// @param caseId the court case, which must be Final.
    /// @param party the disputing address whose reputation is updated.
    /// @param side which side of the dispute `party` was on (caller-asserted).
    function record(uint256 caseId, address party, Side side) external {
        require(!recorded[caseId][party], "already recorded");
        CaseView memory cv = court.getCase(caseId);
        require(cv.status == CaseStatus.Final, "not final");

        recorded[caseId][party] = true;
        Rep storage r = reps[party];
        r.disputes += 1;
        r.lastCaseId = caseId;

        Verdict v = cv.verdict;
        if (v == Verdict.SPLIT) {
            r.splits += 1;
        } else if ((side == Side.Payee && v == Verdict.PAYEE) || (side == Side.Payer && v == Verdict.PAYER)) {
            r.wins += 1;
        } else {
            r.losses += 1;
        }

        emit ReputationRecorded(party, caseId, side, v);
    }

    // --- views ----------------------------------------------------------------

    function reputationOf(address party) external view returns (Rep memory) {
        return reps[party];
    }

    /// @notice Reputation score. Formula: wins weighted double, losses subtracted, splits neutral.
    /// score = wins * 2 - losses. Returns a signed value so a net-negative record is expressible.
    function scoreOf(address party) external view returns (int256) {
        Rep storage r = reps[party];
        return int256(r.wins) * 2 - int256(r.losses);
    }
}
