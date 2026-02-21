//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

library InterestLib {
    uint256 constant PRECISION = 1e18;
    uint256 constant KINK = 80e16;
    uint256 constant YEAR = 365 days;

    function calculateUtilization(
        uint256 totalLiquidity,
        uint256 totalBorrowed
    ) internal pure returns (uint256) {
        if (totalBorrowed == 0) {
            return 0;
        }
        return (totalBorrowed * PRECISION) / totalLiquidity;
    }

    function calculateLenderInterest(
        uint256 borrowRate,
        uint256 utilization,
        uint256 reserveFactor
    ) internal pure returns (uint256) {
        return
            (borrowRate * utilization * (PRECISION - reserveFactor)) /
            (PRECISION * PRECISION);
    }

    function calculateBorrowRate(
        uint256 utilization,
        uint256 baseRate,
        uint256 slope,
        uint256 baseRateAtKink,
        uint256 slopeAtKink
    ) internal pure returns (uint256) {
        if (utilization < KINK) {
            return baseRate + ((utilization * slope) / PRECISION);
        } else {
            return
                baseRateAtKink +
                (((utilization - KINK) * slopeAtKink) / PRECISION);
        }
    }

    function calculateIndexUpdate(
        uint256 timeElapsedSinceUpdate,
        uint256 lenderRate
    ) internal pure returns (uint256) {
        return PRECISION + ((lenderRate * timeElapsedSinceUpdate) / YEAR);
    }

    function calculateInterestAccrued(
        uint256 totalBorrowed,
        uint256 interestRate,
        uint256 timeElapsedSinceUpdate
    ) internal pure returns (uint256) {
        return
            (totalBorrowed * interestRate * timeElapsedSinceUpdate) /
            YEAR /
            PRECISION;
    }
}
