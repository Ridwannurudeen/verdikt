// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title EvidenceLib
/// @notice Canonical, deterministic formatter for VerdiktCourt dispute evidence.
/// An autonomous agent populates the structured fields from on-chain state and calls
/// `format` to produce a byte-identical evidence string. Determinism matters because the
/// court wraps this string into a fixed prompt and a Majority panel must reason over
/// identical input bytes. This does NOT change the court's verdict space — the allowed
/// outputs stay PAYEE/PAYER/SPLIT — it only standardizes the INPUT the panel reads.
library EvidenceLib {
    struct Evidence {
        uint256 dealId;
        address payer;
        address payee;
        uint256 amount;
        uint64 deliverBy;
        uint64 observedAt;
        string claim;
        uint256 priorCaseId; // 0 = none; otherwise cite this case as precedent
    }

    /// @notice Render a structured dispute into the canonical evidence string.
    /// Same struct in => byte-identical string out.
    function format(Evidence memory e) internal pure returns (string memory) {
        string memory prior = e.priorCaseId == 0 ? "none" : _toString(e.priorCaseId);
        return string.concat(
            "dealId=",
            _toString(e.dealId),
            "\npayer=",
            _toHexString(e.payer),
            "\npayee=",
            _toHexString(e.payee),
            "\namount=",
            _toString(e.amount),
            "\ndeliverBy=",
            _toString(e.deliverBy),
            "\nobservedAt=",
            _toString(e.observedAt),
            "\npriorCaseId=",
            prior,
            "\nclaim=",
            e.claim
        );
    }

    /// @dev Decimal string for an unsigned integer.
    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /// @dev Lowercase 0x-prefixed 40-char hex string for an address.
    function _toHexString(address addr) private pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        uint160 value = uint160(addr);
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(value >> (8 * (19 - i)));
            buffer[2 + i * 2] = hexSymbols[b >> 4];
            buffer[3 + i * 2] = hexSymbols[b & 0x0f];
        }
        return string(buffer);
    }
}
