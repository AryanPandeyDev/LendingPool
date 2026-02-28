// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title InterestLib
/// @author AryanPandeyDev
/// @notice Pure math library for interest-rate calculations used by the LendingPool.
/// @dev All rates and values use 18-decimal fixed-point (1e18 = 100 %).
///      The interest-rate curve follows a kinked model:
///        - Below KINK (80 %): rate = baseRate + (utilisation × slope)
///        - At / above KINK:   rate = baseRateAtKink + ((utilisation − KINK) × slopeAtKink)
library InterestLib {
    /// @dev Fixed-point precision constant (1e18).
    uint256 constant PRECISION = 1e18;
    /// @dev Utilisation threshold at which the interest-rate curve steepens (80 %).
    uint256 constant KINK = 80e16;
    /// @dev Seconds in one year — used to annualise / de-annualise rates.
    uint256 constant YEAR = 365 days;

    /// @notice Computes pool utilisation as `totalBorrowed / totalLiquidity`.
    /// @param totalLiquidity The total deposited liquidity (18-decimal).
    /// @param totalBorrowed The total outstanding borrows (18-decimal).
    /// @return The utilisation ratio (1e18 = 100 %). Returns 0 when nothing is borrowed.
    function calculateUtilization(
        uint256 totalLiquidity,
        uint256 totalBorrowed
    ) internal pure returns (uint256) {
        if (totalBorrowed == 0) {
            return 0;
        }
        return (totalBorrowed * PRECISION) / totalLiquidity;
    }

    /// @notice Derives the lender interest rate from the borrow rate, utilisation, and reserve factor.
    /// @dev `lenderRate = borrowRate × utilisation × (1 − reserveFactor)`
    /// @param borrowRate The current annualised borrow rate (18-decimal).
    /// @param utilization The current utilisation ratio (18-decimal).
    /// @param reserveFactor The protocol's reserve factor (18-decimal, e.g. 5e16 = 5 %).
    /// @return The annualised lender rate (18-decimal).
    function calculateLenderInterest(
        uint256 borrowRate,
        uint256 utilization,
        uint256 reserveFactor
    ) internal pure returns (uint256) {
        return
            (borrowRate * utilization * (PRECISION - reserveFactor)) /
            (PRECISION * PRECISION);
    }

    /// @notice Computes the annualised borrow rate from the kinked interest-rate curve.
    /// @param utilization Current pool utilisation (18-decimal).
    /// @param baseRate Base rate below the kink (18-decimal).
    /// @param slope Slope below the kink (18-decimal).
    /// @param baseRateAtKink Base rate at / above the kink (18-decimal).
    /// @param slopeAtKink Slope at / above the kink (18-decimal).
    /// @return The annualised borrow rate (18-decimal).
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

    /// @notice Computes the multiplicative factor to grow a cumulative index over `timeElapsedSinceUpdate` seconds.
    /// @dev `factor = 1 + (rate × dt / YEAR)` — simple (linear) interest for the period.
    /// @param timeElapsedSinceUpdate Seconds since the last index update.
    /// @param lenderRate The annualised rate to apply (18-decimal).
    /// @return The growth factor (18-decimal, ≥ 1e18).
    function calculateIndexUpdate(
        uint256 timeElapsedSinceUpdate,
        uint256 lenderRate
    ) internal pure returns (uint256) {
        return PRECISION + ((lenderRate * timeElapsedSinceUpdate) / YEAR);
    }

    /// @notice Computes absolute interest accrued on a principal over a time period.
    /// @dev `interest = principal × rate × dt / YEAR`
    /// @param totalBorrowed The principal amount (e.g. total borrows or total liquidity).
    /// @param interestRate The annualised rate (18-decimal).
    /// @param timeElapsedSinceUpdate Seconds since the last accrual.
    /// @return The absolute interest amount (same decimals as `totalBorrowed`).
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
