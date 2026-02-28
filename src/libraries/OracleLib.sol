// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title OracleLib
/// @author AryanPandeyDev
/// @notice Wrapper around Chainlink's `AggregatorV3Interface` that adds a staleness check.
/// @dev Attach to `AggregatorV3Interface` via `using OracleLib for AggregatorV3Interface;`.
///      Any call to `staleCheckLatestRoundData` will revert with `OracleLib__StalePrice` if
///      the feed's last update is older than `TIMEOUT`.
library OracleLib {
    /// @dev Thrown when the price feed data is considered stale.
    error OracleLib__StalePrice();

    /// @dev Maximum acceptable age (in seconds) of a price-feed update before it is deemed stale.
    uint256 private constant TIMEOUT = 3 hours;

    /// @notice Fetches the latest round data from a Chainlink feed and reverts if the data is stale.
    /// @dev Staleness is determined by two conditions:
    ///      1. `updatedAt == 0` or `answeredInRound < roundId` → incomplete round.
    ///      2. `block.timestamp − updatedAt > TIMEOUT` → too old.
    /// @param chainlinkFeed The Chainlink aggregator to query.
    /// @return roundId The round ID of the latest answer.
    /// @return answer The price (8-decimal for ETH/USD feeds).
    /// @return startedAt Timestamp when the round started.
    /// @return updatedAt Timestamp of the latest update.
    /// @return answeredInRound The round in which the answer was computed.
    function staleCheckLatestRoundData(
        AggregatorV3Interface chainlinkFeed
    ) public view returns (uint80, int256, uint256, uint256, uint80) {
        (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = chainlinkFeed.latestRoundData();

        if (updatedAt == 0 || answeredInRound < roundId) {
            revert OracleLib__StalePrice();
        }
        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    /// @notice Returns the staleness timeout used by this library.
    /// @return The timeout in seconds (10 800 = 3 hours).
    function getTimeout(
        AggregatorV3Interface /* chainlinkFeed */
    ) public pure returns (uint256) {
        return TIMEOUT;
    }
}
