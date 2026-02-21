//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {InterestLib} from "../../src/libraries/InterestLib.sol";

contract TestInterestLib is Test {
    uint256 constant PRECISION = 1e18;
    uint256 constant KINK = 80e16; // 80%

    // ─── calculateUtilization ───────────────────────────────────────────

    function test_calculateUtilization_zeroBorrowed() public pure {
        uint256 util = InterestLib.calculateUtilization(1000e18, 0);
        assertEq(util, 0);
    }

    function test_calculateUtilization_fiftyPercent() public pure {
        uint256 util = InterestLib.calculateUtilization(1000e18, 500e18);
        assertEq(util, 50e16); // 0.5e18
    }

    function test_calculateUtilization_hundredPercent() public pure {
        uint256 util = InterestLib.calculateUtilization(1000e18, 1000e18);
        assertEq(util, PRECISION); // 1e18
    }

    function test_calculateUtilization_lowValues() public pure {
        uint256 util = InterestLib.calculateUtilization(1, 1);
        assertEq(util, PRECISION);
    }

    function test_calculateUtilization_bothZero() public pure {
        uint256 util = InterestLib.calculateUtilization(0, 0);
        assertEq(util, 0);
    }

    function testFuzz_calculateUtilization(
        uint256 totalLiquidity,
        uint256 totalBorrowed
    ) public pure {
        // Bound so borrowed <= liquidity and liquidity > 0
        totalLiquidity = bound(totalLiquidity, 1, type(uint128).max);
        totalBorrowed = bound(totalBorrowed, 0, totalLiquidity);

        uint256 util = InterestLib.calculateUtilization(
            totalLiquidity,
            totalBorrowed
        );

        // Utilization should never exceed 100%
        assertLe(util, PRECISION);

        // Zero borrowed => zero utilization
        if (totalBorrowed == 0) {
            assertEq(util, 0);
        }
    }

    // ─── calculateBorrowRate ────────────────────────────────────────────

    function test_calculateBorrowRate_zeroUtilization() public pure {
        uint256 baseRate = 2e16; // 2%
        uint256 slope = 8e16; // 8%
        uint256 baseRateAtKink = 0;
        uint256 slopeAtKink = 0;

        uint256 rate = InterestLib.calculateBorrowRate(
            0,
            baseRate,
            slope,
            baseRateAtKink,
            slopeAtKink
        );
        assertEq(rate, baseRate);
    }

    function test_calculateBorrowRate_belowKink() public pure {
        uint256 utilization = 50e16; // 50%
        uint256 baseRate = 2e16; // 2%
        uint256 slope = 8e16; // 8%
        uint256 baseRateAtKink = 0;
        uint256 slopeAtKink = 0;

        uint256 rate = InterestLib.calculateBorrowRate(
            utilization,
            baseRate,
            slope,
            baseRateAtKink,
            slopeAtKink
        );
        // expected: 2% + 50% * 8% = 2% + 4% = 6%
        assertEq(rate, 6e16);
    }

    function test_calculateBorrowRate_exactlyAtKink() public pure {
        uint256 utilization = KINK; // 80%
        uint256 baseRate = 2e16;
        uint256 slope = 10e16;
        uint256 baseRateAtKink = 10e16; // 10%
        uint256 slopeAtKink = 100e16; // 100%

        // utilization < KINK is false (equal), so takes the else branch
        // expected: baseRateAtKink + (80% - 80%) * slopeAtKink = 10%
        uint256 rate = InterestLib.calculateBorrowRate(
            utilization,
            baseRate,
            slope,
            baseRateAtKink,
            slopeAtKink
        );
        assertEq(rate, baseRateAtKink);
    }

    function test_calculateBorrowRate_aboveKink() public pure {
        uint256 utilization = 90e16; // 90%
        uint256 baseRate = 2e16;
        uint256 slope = 10e16;
        uint256 baseRateAtKink = 10e16; // 10%
        uint256 slopeAtKink = 100e16; // 100%

        // expected: 10% + (90% - 80%) * 100% = 10% + 10% = 20%
        uint256 rate = InterestLib.calculateBorrowRate(
            utilization,
            baseRate,
            slope,
            baseRateAtKink,
            slopeAtKink
        );
        assertEq(rate, 20e16);
    }

    function test_calculateBorrowRate_fullUtilization() public pure {
        uint256 utilization = PRECISION; // 100%
        uint256 baseRate = 2e16;
        uint256 slope = 10e16;
        uint256 baseRateAtKink = 10e16;
        uint256 slopeAtKink = 100e16;

        // expected: 10% + (100% - 80%) * 100% = 10% + 20% = 30%
        uint256 rate = InterestLib.calculateBorrowRate(
            utilization,
            baseRate,
            slope,
            baseRateAtKink,
            slopeAtKink
        );
        assertEq(rate, 30e16);
    }

    function testFuzz_calculateBorrowRate_belowKink(
        uint256 utilization
    ) public pure {
        utilization = bound(utilization, 0, KINK - 1);
        uint256 baseRate = 2e16;
        uint256 slope = 8e16;

        uint256 rate = InterestLib.calculateBorrowRate(
            utilization,
            baseRate,
            slope,
            0,
            0
        );

        // Rate should always be >= baseRate below kink
        assertGe(rate, baseRate);
    }

    function testFuzz_calculateBorrowRate_aboveKink(
        uint256 utilization
    ) public pure {
        utilization = bound(utilization, KINK, PRECISION);
        uint256 baseRateAtKink = 10e16;
        uint256 slopeAtKink = 50e16;

        uint256 rate = InterestLib.calculateBorrowRate(
            utilization,
            0,
            0,
            baseRateAtKink,
            slopeAtKink
        );

        // Rate should always be >= baseRateAtKink above kink
        assertGe(rate, baseRateAtKink);
    }

    // ─── calculateLenderInterest ────────────────────────────────────────

    function test_calculateLenderInterest_basic() public pure {
        uint256 borrowRate = 6e16; // 6%
        uint256 utilization = 50e16; // 50%
        uint256 reserveFactor = 5e16; // 5%

        uint256 lenderRate = InterestLib.calculateLenderInterest(
            borrowRate,
            utilization,
            reserveFactor
        );
        // expected: (6% * 50% / 1e18) * (1e18 - 5%) / 1e18
        //         = 3e16 * 95e16 / 1e18
        //         = 285e14 = 2.85%
        assertEq(lenderRate, 285e14);
    }

    function test_calculateLenderInterest_zeroReserveFactor() public pure {
        uint256 borrowRate = 10e16; // 10%
        uint256 utilization = PRECISION; // 100%
        uint256 reserveFactor = 0;

        uint256 lenderRate = InterestLib.calculateLenderInterest(
            borrowRate,
            utilization,
            reserveFactor
        );
        // 10% * 100% * (1 - 0) = 10%
        assertEq(lenderRate, 10e16);
    }

    function test_calculateLenderInterest_fullReserveFactor() public pure {
        uint256 borrowRate = 10e16;
        uint256 utilization = 50e16;
        uint256 reserveFactor = PRECISION; // 100% — protocol takes everything

        uint256 lenderRate = InterestLib.calculateLenderInterest(
            borrowRate,
            utilization,
            reserveFactor
        );
        assertEq(lenderRate, 0);
    }

    function test_calculateLenderInterest_zeroBorrowRate() public pure {
        uint256 lenderRate = InterestLib.calculateLenderInterest(
            0,
            50e16,
            5e16
        );
        assertEq(lenderRate, 0);
    }

    function test_calculateLenderInterest_zeroUtilization() public pure {
        uint256 lenderRate = InterestLib.calculateLenderInterest(
            10e16,
            0,
            5e16
        );
        assertEq(lenderRate, 0);
    }

    function testFuzz_calculateLenderInterest(
        uint256 borrowRate,
        uint256 utilization,
        uint256 reserveFactor
    ) public pure {
        borrowRate = bound(borrowRate, 0, 1e18);
        utilization = bound(utilization, 0, 1e18);
        reserveFactor = bound(reserveFactor, 0, 1e18);

        uint256 lenderRate = InterestLib.calculateLenderInterest(
            borrowRate,
            utilization,
            reserveFactor
        );

        // Lender rate should never exceed borrow rate * utilization (before reserve cut)
        uint256 maxRate = (borrowRate * utilization) / PRECISION;
        assertLe(lenderRate, maxRate);
    }

    // ─── calculateIndexUpdate ───────────────────────────────────────────

    function test_calculateIndexUpdate_zeroTimeElapsed() public pure {
        uint256 factor = InterestLib.calculateIndexUpdate(0, 10e16);
        // 1e18 + (10e16 * 0) / 365 days = 1e18
        assertEq(factor, PRECISION);
    }

    function test_calculateIndexUpdate_oneYear() public pure {
        uint256 lenderRate = 10e16; // 10%
        uint256 factor = InterestLib.calculateIndexUpdate(365 days, lenderRate);
        // 1e18 + (10e16 * 365 days) / 365 days = 1e18 + 10e16 = 1.1e18
        assertEq(factor, PRECISION + lenderRate);
    }

    function test_calculateIndexUpdate_halfYear() public pure {
        uint256 lenderRate = 10e16; // 10%
        uint256 halfYear = 365 days / 2;
        uint256 factor = InterestLib.calculateIndexUpdate(halfYear, lenderRate);
        // 1e18 + (10e16 * halfYear) / 365 days = 1e18 + 5e16 = 1.05e18
        assertEq(factor, PRECISION + (lenderRate / 2));
    }

    function test_calculateIndexUpdate_zeroRate() public pure {
        uint256 factor = InterestLib.calculateIndexUpdate(365 days, 0);
        assertEq(factor, PRECISION);
    }

    function test_calculateIndexUpdate_oneDay() public pure {
        uint256 lenderRate = 365e16; // 365% APR for easy math
        uint256 factor = InterestLib.calculateIndexUpdate(1 days, lenderRate);
        // 1e18 + (365e16 * 86400) / (365 * 86400) = 1e18 + 1e16
        assertEq(factor, PRECISION + 1e16);
    }

    function testFuzz_calculateIndexUpdate(
        uint256 timeElapsed,
        uint256 lenderRate
    ) public pure {
        // Keep values reasonable to avoid overflow
        timeElapsed = bound(timeElapsed, 0, 365 days * 10);
        lenderRate = bound(lenderRate, 0, 10e18); // up to 1000%

        uint256 factor = InterestLib.calculateIndexUpdate(
            timeElapsed,
            lenderRate
        );

        // Factor should always be >= PRECISION (index can only grow)
        assertGe(factor, PRECISION);
    }

    // ─── calculateInterestAccured ───────────────────────────────────────

    function test_calculateInterestAccured_zeroTime() public pure {
        uint256 interest = InterestLib.calculateInterestAccured(
            1000e18, // totalBorrowed
            10e16, // 10% rate
            0 // no time elapsed
        );
        assertEq(interest, 0);
    }

    function test_calculateInterestAccured_zeroRate() public pure {
        uint256 interest = InterestLib.calculateInterestAccured(
            1000e18,
            0, // 0% rate
            365 days
        );
        assertEq(interest, 0);
    }

    function test_calculateInterestAccured_zeroBorrowed() public pure {
        uint256 interest = InterestLib.calculateInterestAccured(
            0, // nothing borrowed
            10e16,
            365 days
        );
        assertEq(interest, 0);
    }

    function test_calculateInterestAccured_oneYear() public pure {
        uint256 totalBorrowed = 1000e18;
        uint256 rate = 10e16; // 10%
        uint256 interest = InterestLib.calculateInterestAccured(
            totalBorrowed,
            rate,
            365 days
        );
        // expected: 1000e18 * 10e16 * 365 days / 365 days / 1e18 = 100e18
        assertEq(interest, 100e18);
    }

    function test_calculateInterestAccured_halfYear() public pure {
        uint256 totalBorrowed = 1000e18;
        uint256 rate = 10e16; // 10%
        uint256 halfYear = 365 days / 2;
        uint256 interest = InterestLib.calculateInterestAccured(
            totalBorrowed,
            rate,
            halfYear
        );
        // expected: 1000e18 * 10e16 * (365/2 days) / 365 days / 1e18 = 50e18
        assertEq(interest, 50e18);
    }

    function test_calculateInterestAccured_oneDay() public pure {
        uint256 totalBorrowed = 365e18; // 365 tokens for easy math
        uint256 rate = PRECISION; // 100% APR
        uint256 interest = InterestLib.calculateInterestAccured(
            totalBorrowed,
            rate,
            1 days
        );
        // expected: 365e18 * 1e18 * 86400 / (365 * 86400) / 1e18 = 1e18
        assertEq(interest, 1e18);
    }

    function test_calculateInterestAccured_smallAmount() public pure {
        uint256 totalBorrowed = 1e18; // 1 token
        uint256 rate = 5e16; // 5%
        uint256 interest = InterestLib.calculateInterestAccured(
            totalBorrowed,
            rate,
            365 days
        );
        // expected: 1e18 * 5e16 * 365 days / 365 days / 1e18 = 5e16
        assertEq(interest, 5e16);
    }

    function testFuzz_calculateInterestAccured(
        uint256 totalBorrowed,
        uint256 rate,
        uint256 timeElapsed
    ) public pure {
        // Bound to avoid overflow: totalBorrowed * rate * time must fit uint256
        totalBorrowed = bound(totalBorrowed, 0, type(uint128).max);
        rate = bound(rate, 0, 10e18); // up to 1000% APR
        timeElapsed = bound(timeElapsed, 0, 365 days * 10);

        uint256 interest = InterestLib.calculateInterestAccured(
            totalBorrowed,
            rate,
            timeElapsed
        );

        // Interest should be zero when any input is zero
        if (totalBorrowed == 0 || rate == 0 || timeElapsed == 0) {
            assertEq(interest, 0);
        }

        // Interest over a full year should not exceed totalBorrowed * rate / PRECISION
        if (timeElapsed <= 365 days) {
            uint256 maxInterest = (totalBorrowed * rate) / PRECISION;
            assertLe(interest, maxInterest);
        }
    }
}
