// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVerdiktCourt} from "./interfaces/IVerdiktCourt.sol";

/// @title VerdiktCourtRegistry
/// @notice A discovery layer over many VerdiktCourt deployments. Each court is its own
/// configuration (panel/agent model, pricing, SLA); operators list theirs here so that
/// consumers and agents can shop juries by live price (quoteOpen) and SLA. Verdikt as a
/// meta-layer over independent AI juries.
contract VerdiktCourtRegistry {
    struct CourtListing {
        address court;
        address operator;
        string name;
        string model;
        uint256 slaSeconds;
        bool active;
        uint64 registeredAt;
    }

    /// @notice court address => listing
    mapping(address => CourtListing) private listings;
    /// @notice every registered court address, in registration order.
    address[] private courts;

    event CourtRegistered(
        uint256 indexed id,
        address indexed court,
        address indexed operator,
        string name,
        string model,
        uint256 slaSeconds
    );
    event CourtUpdated(address indexed court, string name, string model, uint256 slaSeconds);
    event CourtDeactivated(address indexed court);
    event CourtReactivated(address indexed court);

    modifier onlyOperator(address court) {
        require(listings[court].court != address(0), "not registered");
        require(msg.sender == listings[court].operator, "not operator");
        _;
    }

    /// @notice List a VerdiktCourt deployment. Caller becomes its operator.
    function registerCourt(address court, string calldata name, string calldata model, uint256 slaSeconds)
        external
        returns (uint256 id)
    {
        require(court != address(0), "zero court");
        require(listings[court].court == address(0), "already registered");

        id = courts.length;
        listings[court] = CourtListing({
            court: court,
            operator: msg.sender,
            name: name,
            model: model,
            slaSeconds: slaSeconds,
            active: true,
            registeredAt: uint64(block.timestamp)
        });
        courts.push(court);
        emit CourtRegistered(id, court, msg.sender, name, model, slaSeconds);
    }

    /// @notice Activate or deactivate a listing (only that court's operator).
    function setActive(address court, bool active) external onlyOperator(court) {
        listings[court].active = active;
        if (active) {
            emit CourtReactivated(court);
        } else {
            emit CourtDeactivated(court);
        }
    }

    /// @notice Update a listing's descriptive metadata (only that court's operator).
    function updateListing(address court, string calldata name, string calldata model, uint256 slaSeconds)
        external
        onlyOperator(court)
    {
        CourtListing storage l = listings[court];
        l.name = name;
        l.model = model;
        l.slaSeconds = slaSeconds;
        emit CourtUpdated(court, name, model, slaSeconds);
    }

    // --- views ----------------------------------------------------------------

    function courtsCount() external view returns (uint256) {
        return courts.length;
    }

    /// @notice Paginated list of registered court addresses.
    function listCourts(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = courts.length;
        if (offset >= n) {
            return new address[](0);
        }
        uint256 end = offset + limit;
        if (end > n) {
            end = n;
        }
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = courts[i];
        }
    }

    function getListing(address court) external view returns (CourtListing memory) {
        require(listings[court].court != address(0), "not registered");
        return listings[court];
    }

    /// @notice Live open-case quote read straight from the court.
    function quoteFor(address court) external view returns (uint256) {
        require(listings[court].court != address(0), "not registered");
        return IVerdiktCourt(court).quoteOpen();
    }

    /// @notice Scan active listings and return the court with the lowest live quoteOpen.
    function cheapest() external view returns (address court, uint256 fee) {
        bool found;
        uint256 n = courts.length;
        for (uint256 i = 0; i < n; i++) {
            address c = courts[i];
            if (!listings[c].active) {
                continue;
            }
            uint256 q = IVerdiktCourt(c).quoteOpen();
            if (!found || q < fee) {
                found = true;
                court = c;
                fee = q;
            }
        }
        require(found, "no active courts");
    }
}
