// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktMarketplace
/// @notice The economic layer over the court registry: operators put a STAKE behind the court they
/// run, so listings have skin in the game. Anyone can CHALLENGE a court's ruling by posting a bond;
/// governance (owner / timelock) resolves it — an upheld challenge SLASHES the court's stake to the
/// challenger + treasury, a rejected one pays the bond to the operator (anti-frivolous). Routing is
/// quality-weighted (`bestCourt`), so honest, well-staked courts win the flow. All payouts go through
/// a pull-payment ledger so a reverting recipient can never brick resolution. A market for justice.
contract VerdiktMarketplace {
    address public owner;
    address public treasury;
    uint256 public minStake = 1 ether;
    uint256 public challengeBond = 0.2 ether;
    uint256 public slashBps = 2000; // 20% of stake slashed on an upheld challenge
    uint64 public withdrawDelay = 7 days;

    struct Backing {
        address operator;
        uint256 stake;
        string label;
        bool active;
        uint64 unbondingAt; // 0 unless unbonding
        uint64 challengesUpheld;
        uint64 challengesRejected;
    }

    struct Challenge {
        address challenger;
        uint256 caseId;
        uint256 bond;
        bool open;
    }

    mapping(address => Backing) public backing; // court => backing
    mapping(address => Challenge) public challenges; // court => current challenge
    mapping(address => uint256) public pending; // pull-payment ledger
    address[] public backedCourts;
    bool private _entered;

    event CourtBacked(address indexed court, address indexed operator, uint256 stake, string label);
    event StakeAdded(address indexed court, uint256 amount, uint256 total);
    event UnbondStarted(address indexed court, uint64 withdrawableAt);
    event StakeWithdrawn(address indexed court, address indexed operator, uint256 amount);
    event Challenged(address indexed court, address indexed challenger, uint256 caseId, uint256 bond);
    event ChallengeResolved(address indexed court, bool upheld, uint256 slashed);
    event Withdrawn(address indexed to, uint256 amount);
    event ParamsSet(uint256 minStake, uint256 challengeBond, uint256 slashBps, uint64 withdrawDelay);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyOperator(address court) {
        require(backing[court].operator == msg.sender, "not operator");
        _;
    }

    modifier nonReentrant() {
        require(!_entered, "reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address treasury_) {
        require(treasury_ != address(0), "zero treasury");
        owner = msg.sender;
        treasury = treasury_;
    }

    // --- operator: back / top up / exit ---------------------------------------

    /// @notice Stake to back a court you operate. Reverts if the court isn't a working VerdiktCourt.
    function backCourt(address court, string calldata label) external payable nonReentrant {
        require(court != address(0), "zero court");
        require(backing[court].operator == address(0), "already backed");
        require(msg.value >= minStake, "stake too low");
        uint256 quote = IVerdiktCourt(court).quoteOpen(); // validates the court responds
        require(quote > 0, "bad court");
        backing[court] = Backing(msg.sender, msg.value, label, true, 0, 0, 0);
        backedCourts.push(court);
        emit CourtBacked(court, msg.sender, msg.value, label);
    }

    function addStake(address court) external payable onlyOperator(court) {
        require(msg.value > 0, "no value");
        backing[court].stake += msg.value;
        emit StakeAdded(court, msg.value, backing[court].stake);
    }

    /// @notice Begin unbonding: deactivate the listing and start the withdraw timer.
    function beginUnbond(address court) external onlyOperator(court) {
        Backing storage b = backing[court];
        b.active = false;
        b.unbondingAt = uint64(block.timestamp) + withdrawDelay;
        emit UnbondStarted(court, b.unbondingAt);
    }

    /// @notice Withdraw the remaining stake after the delay, if no challenge is open.
    function withdrawStake(address court) external onlyOperator(court) {
        Backing storage b = backing[court];
        require(b.unbondingAt != 0 && block.timestamp >= b.unbondingAt, "still bonded");
        require(!challenges[court].open, "challenge open");
        uint256 amount = b.stake;
        address op = b.operator;
        delete backing[court];
        pending[op] += amount;
        emit StakeWithdrawn(court, op, amount);
    }

    // --- challenge / resolve --------------------------------------------------

    /// @notice Challenge a court's handling of `caseId` by posting a bond. One open challenge per court.
    function challenge(address court, uint256 caseId) external payable {
        require(backing[court].operator != address(0), "not backed");
        require(!challenges[court].open, "challenge pending");
        require(msg.value >= challengeBond, "bond too low");
        challenges[court] = Challenge(msg.sender, caseId, msg.value, true);
        emit Challenged(court, msg.sender, caseId, msg.value);
    }

    /// @notice Governance resolves an open challenge. `upheld` = the court ruled badly.
    function resolveChallenge(address court, bool upheld) external onlyOwner {
        Challenge storage ch = challenges[court];
        require(ch.open, "no challenge");
        ch.open = false;
        Backing storage b = backing[court];

        if (upheld) {
            uint256 slash = (b.stake * slashBps) / 10000;
            b.stake -= slash;
            b.challengesUpheld += 1;
            uint256 toTreasury = slash / 2;
            pending[treasury] += toTreasury;
            // challenger is made whole (bond) and rewarded the rest of the slash
            pending[ch.challenger] += (slash - toTreasury) + ch.bond;
            emit ChallengeResolved(court, true, slash);
        } else {
            b.challengesRejected += 1;
            // frivolous challenge: the bond goes to the operator
            pending[b.operator] += ch.bond;
            emit ChallengeResolved(court, false, 0);
        }
    }

    // --- pull payments --------------------------------------------------------

    function withdraw() external nonReentrant returns (uint256 amount) {
        amount = pending[msg.sender];
        require(amount > 0, "nothing to withdraw");
        pending[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw failed");
        emit Withdrawn(msg.sender, amount);
    }

    // --- routing / views ------------------------------------------------------

    /// @notice Quality score: rejected challenges build trust (+1), upheld ones hurt 3x.
    function score(address court) public view returns (int256) {
        Backing storage b = backing[court];
        return int256(uint256(b.challengesRejected)) - int256(uint256(b.challengesUpheld)) * 3;
    }

    /// @notice Route to the best active court: highest score, then cheapest live quote, breaking ties
    /// toward the larger stake. Skin-in-the-game and a clean record win the flow.
    function bestCourt() external view returns (address court, uint256 fee) {
        bool found = false;
        int256 bestScore = 0;
        uint256 bestFee = 0;
        uint256 bestStake = 0;
        uint256 n = backedCourts.length;
        for (uint256 i = 0; i < n; i++) {
            address c = backedCourts[i];
            Backing storage b = backing[c];
            if (!b.active || b.operator == address(0)) continue;
            uint256 q = 0;
            try IVerdiktCourt(c).quoteOpen() returns (uint256 quote) {
                q = quote;
            } catch {
                continue;
            }
            int256 s = score(c);
            bool better = !found || s > bestScore || (s == bestScore && q < bestFee)
                || (s == bestScore && q == bestFee && b.stake > bestStake);
            if (better) {
                found = true;
                bestScore = s;
                bestFee = q;
                bestStake = b.stake;
                court = c;
                fee = q;
            }
        }
        require(found, "no active courts");
    }

    function backedCount() external view returns (uint256) {
        return backedCourts.length;
    }

    // --- admin ----------------------------------------------------------------

    function setParams(uint256 minStake_, uint256 challengeBond_, uint256 slashBps_, uint64 withdrawDelay_)
        external
        onlyOwner
    {
        require(slashBps_ <= 10000, "bps");
        minStake = minStake_;
        challengeBond = challengeBond_;
        slashBps = slashBps_;
        withdrawDelay = withdrawDelay_;
        emit ParamsSet(minStake_, challengeBond_, slashBps_, withdrawDelay_);
    }

    function setTreasury(address t) external onlyOwner {
        require(t != address(0), "zero treasury");
        treasury = t;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
