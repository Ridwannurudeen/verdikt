// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VerdiktTimelock
/// @notice A generic delayed-execution governor. It can own any contract (e.g. VerdiktCourt)
/// so that privileged actions are subject to a mandatory delay: the admin queues a call,
/// waits out the timelock, then executes it. This removes single-key, instant owner trust.
contract VerdiktTimelock {
    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;

    address public admin;
    uint256 public delay;

    mapping(bytes32 => bool) public queued;

    event Queued(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);
    event Executed(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta);
    event Cancelled(bytes32 indexed txHash);

    modifier onlyAdmin() {
        require(msg.sender == admin, "not admin");
        _;
    }

    constructor(address admin_, uint256 delay_) {
        require(admin_ != address(0), "admin zero");
        require(delay_ >= MIN_DELAY, "delay too low");
        require(delay_ <= MAX_DELAY, "delay too high");
        admin = admin_;
        delay = delay_;
    }

    function queue(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        onlyAdmin
        returns (bytes32 txHash)
    {
        require(eta >= block.timestamp + delay, "eta too soon");
        txHash = keccak256(abi.encode(target, value, data, eta));
        queued[txHash] = true;
        emit Queued(txHash, target, value, data, eta);
    }

    function execute(address target, uint256 value, bytes calldata data, uint256 eta)
        external
        payable
        onlyAdmin
        returns (bytes memory)
    {
        bytes32 txHash = keccak256(abi.encode(target, value, data, eta));
        require(queued[txHash], "not queued");
        require(block.timestamp >= eta, "not ready");
        delete queued[txHash];

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok, "call failed");
        emit Executed(txHash, target, value, data, eta);
        return ret;
    }

    function cancel(bytes32 txHash) external onlyAdmin {
        delete queued[txHash];
        emit Cancelled(txHash);
    }

    receive() external payable {}
}
