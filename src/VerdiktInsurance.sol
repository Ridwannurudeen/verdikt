// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt, IVerdiktConsumer, Verdict, CaseStatus, CaseView} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktInsurance
/// @notice A parametric claims-arbitration pool resolved by VerdiktCourt's AI panel.
/// Funders deposit STT into a shared pool that pays winning claims; insureds buy policies by
/// paying a premium (added to the pool) and file claims with evidence. The losing side can
/// appeal by posting a stake; on uphold the stake is slashed to the counterparty minus a
/// treasury cut, mirroring VerdiktEscrow's economics.
contract VerdiktInsurance is IVerdiktConsumer {
    IVerdiktCourt public immutable court;
    address public owner;
    address public treasury;

    /// @dev premium as a fraction of coverage (bps). 500 = 5%.
    uint256 public premiumBps = 500;
    /// @dev appeal stake as a fraction of coverage (bps). 1000 = 10%.
    uint256 public appealStakeBps = 1000;
    /// @dev cut of a slashed stake routed to the treasury (bps of the stake). 500 = 5%.
    uint256 public keeperCutBps = 500;

    enum PolicyStatus {
        None,
        Active,
        Expired,
        Exhausted
    }

    enum ClaimStatus {
        None,
        Filed,
        Settled
    }

    struct Policy {
        address insured;
        uint256 coverage;
        uint64 expiry;
        PolicyStatus status;
        uint256 activeClaimId;
    }

    struct Claim {
        uint256 policyId;
        ClaimStatus status;
        uint256 caseId;
    }

    struct AppealInfo {
        address appellant;
        uint256 stake;
        Verdict preAppealVerdict;
        bool fromPool; // true if appellant is a pool funder (counterparty = insured); false if insured (counterparty = pool)
        bool active;
    }

    /// @dev pool accounting: shares track each funder's stake; totalPool is the STT owned by the pool.
    /// Pool grows on fundPool + premium + slashed appeal stakes; shrinks on claim payouts + withdrawals.
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalPool;

    /// @dev simple lock to prevent rug-on-claim: withdrawals are blocked while any claim is Filed.
    uint256 public openClaimCount;

    uint256 public nextPolicyId = 1;
    uint256 public nextClaimId = 1;
    mapping(uint256 => Policy) public policies;
    mapping(uint256 => Claim) public claims;
    mapping(uint256 => AppealInfo) public appeals;
    /// @notice court caseId => claimId, so onVerdict can route by escrowRef.
    mapping(uint256 => uint256) public caseToClaim;

    event PoolFunded(address indexed funder, uint256 amount, uint256 sharesMinted);
    event PolicyCreated(
        uint256 indexed policyId, address indexed insured, uint256 coverage, uint256 premium, uint64 expiry
    );
    event ClaimFiled(uint256 indexed claimId, uint256 indexed policyId, uint256 indexed caseId, address by);
    event ClaimAppealed(uint256 indexed claimId, address indexed appellant, uint256 stake, Verdict preAppealVerdict);
    event ClaimSettled(uint256 indexed claimId, Verdict verdict, uint256 payout);
    event StakeSlashed(uint256 indexed claimId, address loser, address winner, uint256 toWinner, uint256 toTreasury);
    event StakeReturned(uint256 indexed claimId, address appellant, uint256 amount);
    event PoolWithdrawn(address indexed funder, uint256 sharesBurned, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address court_, address treasury_) {
        court = IVerdiktCourt(court_);
        owner = msg.sender;
        treasury = treasury_;
    }

    // --- pool -----------------------------------------------------------------

    function fundPool() external payable {
        require(msg.value > 0, "no funds");
        shares[msg.sender] += msg.value;
        totalShares += msg.value;
        totalPool += msg.value;
        emit PoolFunded(msg.sender, msg.value, msg.value);
    }

    /// @notice Burn `shareCount` shares and receive a pro-rata slice of the pool.
    /// Locked while any claim is Filed so payable losses can't be front-run by withdrawals.
    function withdrawPool(uint256 shareCount) external {
        require(openClaimCount == 0, "claims open");
        require(shareCount > 0 && shareCount <= shares[msg.sender], "bad shares");
        uint256 payout = (shareCount * totalPool) / totalShares;
        shares[msg.sender] -= shareCount;
        totalShares -= shareCount;
        totalPool -= payout;
        _pay(msg.sender, payout);
        emit PoolWithdrawn(msg.sender, shareCount, payout);
    }

    // --- policy ---------------------------------------------------------------

    function createPolicy(uint256 coverage, uint64 expiry) external payable returns (uint256 policyId) {
        require(coverage > 0, "no coverage");
        require(expiry > block.timestamp, "bad expiry");
        uint256 premium = (coverage * premiumBps) / 10000;
        require(msg.value >= premium, "premium too low");

        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            insured: msg.sender, coverage: coverage, expiry: expiry, status: PolicyStatus.Active, activeClaimId: 0
        });
        totalPool += premium;
        _refundExcess(msg.value, premium);
        emit PolicyCreated(policyId, msg.sender, coverage, premium, expiry);
    }

    // --- claim + appeal -------------------------------------------------------

    function fileClaim(uint256 policyId, string calldata evidence) external payable returns (uint256 claimId) {
        Policy storage p = policies[policyId];
        require(msg.sender == p.insured, "only insured");
        require(p.status == PolicyStatus.Active, "policy inactive");
        require(block.timestamp <= p.expiry, "policy expired");
        require(p.activeClaimId == 0, "claim open");

        uint256 fee = court.quoteOpen();
        require(msg.value >= fee, "fee too low");

        claimId = nextClaimId++;
        uint256 caseId = court.openCase{value: fee}(claimId, evidence);
        claims[claimId] = Claim({policyId: policyId, status: ClaimStatus.Filed, caseId: caseId});
        p.activeClaimId = claimId;
        caseToClaim[caseId] = claimId;
        openClaimCount += 1;
        _refundExcess(msg.value, fee);
        emit ClaimFiled(claimId, policyId, caseId, msg.sender);
    }

    function appealClaim(uint256 claimId, string calldata newEvidence) external payable {
        Claim storage c = claims[claimId];
        require(c.status == ClaimStatus.Filed, "not filed");
        require(!appeals[claimId].active, "already appealed");

        Policy storage p = policies[c.policyId];
        CaseView memory cv = court.getCase(c.caseId);
        require(cv.status == CaseStatus.Ruled, "no verdict yet");

        // PAYEE pays the insured (pool loses), so only a pool funder can appeal it.
        // PAYER pays nothing (insured loses), so only the insured can appeal it.
        // SPLIT splits the loss across both, so either side may appeal.
        bool fromPool;
        if (cv.verdict == Verdict.PAYEE) {
            require(shares[msg.sender] > 0, "only pool funder");
            fromPool = true;
        } else if (cv.verdict == Verdict.PAYER) {
            require(msg.sender == p.insured, "only insured");
            fromPool = false;
        } else {
            // SPLIT
            if (msg.sender == p.insured) {
                fromPool = false;
            } else {
                require(shares[msg.sender] > 0, "only party");
                fromPool = true;
            }
        }

        uint256 stake = (p.coverage * appealStakeBps) / 10000;
        uint256 agentDep = court.quoteAppeal(c.caseId);
        require(msg.value >= stake + agentDep, "value too low");

        appeals[claimId] = AppealInfo({
            appellant: msg.sender, stake: stake, preAppealVerdict: cv.verdict, fromPool: fromPool, active: true
        });

        court.appeal{value: agentDep}(c.caseId, newEvidence);
        _refundExcess(msg.value, stake + agentDep);
        emit ClaimAppealed(claimId, msg.sender, stake, cv.verdict);
    }

    // --- court callback -------------------------------------------------------

    function onVerdict(uint256 escrowRef, Verdict verdict) external override {
        require(msg.sender == address(court), "only court");
        Claim storage c = claims[escrowRef];
        require(c.status == ClaimStatus.Filed, "not filed");

        Policy storage p = policies[c.policyId];
        uint256 payout = _payout(verdict, p.coverage);

        c.status = ClaimStatus.Settled;
        p.activeClaimId = 0;
        // PAYER leaves the policy usable if it hasn't lapsed; any payout exhausts coverage.
        if (payout > 0) {
            p.status = PolicyStatus.Exhausted;
            totalPool -= payout;
            _pay(p.insured, payout);
        } else if (block.timestamp > p.expiry) {
            p.status = PolicyStatus.Expired;
        }
        openClaimCount -= 1;
        emit ClaimSettled(escrowRef, verdict, payout);

        AppealInfo storage a = appeals[escrowRef];
        if (a.active) {
            a.active = false;
            if (verdict == a.preAppealVerdict) {
                // appeal failed: slash stake to the counterparty side (minus treasury cut).
                uint256 cut = (a.stake * keeperCutBps) / 10000;
                uint256 toWinner = a.stake - cut;
                if (cut > 0) _pay(treasury, cut);
                if (a.fromPool) {
                    // pool appellant lost -> insured wins the stake
                    if (toWinner > 0) _pay(p.insured, toWinner);
                    emit StakeSlashed(escrowRef, a.appellant, p.insured, toWinner, cut);
                } else {
                    // insured appellant lost -> pool wins the stake
                    totalPool += toWinner;
                    emit StakeSlashed(escrowRef, a.appellant, address(this), toWinner, cut);
                }
            } else {
                _pay(a.appellant, a.stake);
                emit StakeReturned(escrowRef, a.appellant, a.stake);
            }
        }
    }

    // --- internals ------------------------------------------------------------

    function _payout(Verdict verdict, uint256 coverage) internal pure returns (uint256) {
        if (verdict == Verdict.PAYEE) return coverage;
        if (verdict == Verdict.SPLIT) return coverage / 2;
        return 0; // PAYER (or NONE) -> no payout
    }

    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    function _refundExcess(uint256 sent, uint256 used) internal {
        if (sent > used) {
            (bool ok,) = msg.sender.call{value: sent - used}("");
            require(ok, "refund failed");
        }
    }

    // --- admin ----------------------------------------------------------------

    function setPremiumBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "bps");
        premiumBps = bps;
    }

    function setAppealStakeBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "bps");
        appealStakeBps = bps;
    }

    function setKeeperCutBps(uint256 bps) external onlyOwner {
        require(bps <= 10000, "bps");
        keeperCutBps = bps;
    }

    function setTreasury(address t) external onlyOwner {
        treasury = t;
    }

    receive() external payable {}
}
