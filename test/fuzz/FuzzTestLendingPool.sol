// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {DeployLendingPool} from "../../script/DeployLendingPool.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {CodeConstant} from "../../script/HelperConfig.s.sol";
import {InterestLib} from "../../src/libraries/InterestLib.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {FakeERC20} from "../mocks/FakeERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract FuzzTestLendingPool is Test, CodeConstant {
    uint256 private constant YEAR = 365 days;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    LendingPool private lendingPool;
    HelperConfig private helperConfig;
    FakeERC20 private usdc;
    FakeERC20 private weth;
    MockV3Aggregator private priceFeed;

    address private OPERATOR;
    address private USER = makeAddr("user");
    address private USER2 = makeAddr("user2");
    address private USER3 = makeAddr("user3");

    function setUp() external {
        OPERATOR = makeAddr("operator");

        DeployLendingPool deployer = new DeployLendingPool();
        (lendingPool, helperConfig) = deployer.deploy(OPERATOR);

        usdc = FakeERC20(lendingPool.getUnderlyingAssetAddress());
        weth = FakeERC20(lendingPool.getCollateralAddress());

        (, , , , , , , address priceFeedAddr) = helperConfig.activeConfig();
        priceFeed = MockV3Aggregator(priceFeedAddr);

        _seedAndApprove(USER);
        _seedAndApprove(USER2);
        _seedAndApprove(USER3);
    }

    ///////////////////
    // Helpers
    ///////////////////

    function _seedAndApprove(address actor) internal {
        usdc.mint(actor, 1_000_000 ether);
        weth.mint(actor, 1_000_000 ether);

        vm.startPrank(actor);
        usdc.approve(address(lendingPool), type(uint256).max);
        weth.approve(address(lendingPool), type(uint256).max);
        vm.stopPrank();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _warpAndRefreshOracle(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        priceFeed.updateAnswer(ETH_USD_PRICE);
    }

    function _expectedBorrowRate(
        uint256 totalLiquidity,
        uint256 totalBorrowed
    ) internal pure returns (uint256) {
        uint256 utilization = InterestLib.calculateUtilization(
            totalLiquidity,
            totalBorrowed
        );
        return
            InterestLib.calculateBorrowRate(
                utilization,
                BASE_RATE,
                SLOPE,
                BASE_RATE_AT_KINK,
                SLOPE_AT_KINK
            );
    }

    function _interest(
        uint256 principal,
        uint256 rate,
        uint256 dt
    ) internal pure returns (uint256) {
        return InterestLib.calculateInterestAccrued(principal, rate, dt);
    }

    function _expectedLiquidationCollateral(
        uint256 debtToCover,
        uint256 price
    ) internal pure returns (uint256) {
        uint256 tokenAmountFromDebtCovered = (debtToCover * PRECISION) /
            (price * ADDITIONAL_FEED_PRECISION);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * 5) / 100;
        return tokenAmountFromDebtCovered + bonusCollateral;
    }

    ///////////////////
    // Deposit / Withdraw
    ///////////////////

    function testFuzz_DepositToken_UpdatesBalances(uint96 amountRaw) external {
        uint256 amount = bound(uint256(amountRaw), 1, 200_000 ether);

        uint256 userUsdcBefore = usdc.balanceOf(USER);
        uint256 poolUsdcBefore = usdc.balanceOf(address(lendingPool));

        vm.prank(USER);
        lendingPool.depositToken(amount);

        assertEq(userUsdcBefore - usdc.balanceOf(USER), amount);
        assertEq(usdc.balanceOf(address(lendingPool)) - poolUsdcBefore, amount);
    }

    function testFuzz_DepositAndWithdrawToken_MultiUser(
        uint96 userDepositRaw,
        uint96 user3DepositRaw,
        uint96 withdrawRaw
    ) external {
        uint256 userDeposit = bound(uint256(userDepositRaw), 2, 200_000 ether);
        uint256 user3Deposit = bound(
            uint256(user3DepositRaw),
            1,
            200_000 ether
        );

        vm.prank(USER);
        lendingPool.depositToken(userDeposit);
        vm.prank(USER3);
        lendingPool.depositToken(user3Deposit);

        uint256 withdrawAmount = bound(uint256(withdrawRaw), 1, userDeposit);
        uint256 userUsdcBefore = usdc.balanceOf(USER);
        uint256 poolUsdcBefore = usdc.balanceOf(address(lendingPool));

        vm.prank(USER);
        lendingPool.withdrawToken(withdrawAmount);

        assertEq(usdc.balanceOf(USER) - userUsdcBefore, withdrawAmount);
        assertEq(
            poolUsdcBefore - usdc.balanceOf(address(lendingPool)),
            withdrawAmount
        );
    }

    function testFuzz_WithdrawToken_RevertsWhenOtherUserBorrowedLiquidity(
        uint96 depositRaw,
        uint96 borrowRaw
    ) external {
        uint256 depositAmount = bound(
            uint256(depositRaw),
            1_000 ether,
            200_000 ether
        );
        uint256 maxBorrow = _min(depositAmount - 1, 150_000 ether);
        uint256 borrowAmount = bound(uint256(borrowRaw), 1, maxBorrow);

        vm.prank(USER);
        lendingPool.depositToken(depositAmount);

        vm.startPrank(USER2);
        lendingPool.depositCollateral(100 ether);
        lendingPool.borrowToken(borrowAmount);
        vm.stopPrank();

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__NotEnoughLiquidityAvailable.selector
        );
        lendingPool.withdrawToken(depositAmount);
    }

    ///////////////////
    // Borrow / Repay
    ///////////////////

    function testFuzz_BorrowToken_UsesPooledLiquidityAcrossUsers(
        uint96 userLiquidityRaw,
        uint96 user3LiquidityRaw,
        uint96 collateralRaw,
        uint96 borrowRaw
    ) external {
        uint256 userLiquidity = bound(
            uint256(userLiquidityRaw),
            100 ether,
            400_000 ether
        );
        uint256 user3Liquidity = bound(
            uint256(user3LiquidityRaw),
            100 ether,
            400_000 ether
        );
        uint256 totalLiquidity = userLiquidity + user3Liquidity;

        uint256 collateralAmount = bound(
            uint256(collateralRaw),
            1 ether,
            300 ether
        );
        uint256 maxBorrowFromCollateral = collateralAmount * 1500;
        uint256 borrowAmount = bound(
            uint256(borrowRaw),
            1,
            _min(totalLiquidity, maxBorrowFromCollateral)
        );

        vm.prank(USER);
        lendingPool.depositToken(userLiquidity);
        vm.prank(USER3);
        lendingPool.depositToken(user3Liquidity);

        uint256 borrowerUsdcBefore = usdc.balanceOf(USER2);
        uint256 poolUsdcBefore = usdc.balanceOf(address(lendingPool));

        vm.startPrank(USER2);
        lendingPool.depositCollateral(collateralAmount);
        lendingPool.borrowToken(borrowAmount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(USER2) - borrowerUsdcBefore, borrowAmount);
        assertEq(
            poolUsdcBefore - usdc.balanceOf(address(lendingPool)),
            borrowAmount
        );
    }

    function testFuzz_BorrowToken_RevertsIfHealthFactorBroken(
        uint96 collateralRaw,
        uint96 extraBorrowRaw
    ) external {
        uint256 collateralAmount = bound(
            uint256(collateralRaw),
            1 ether,
            300 ether
        );
        uint256 maxBorrow = collateralAmount * 1500;
        uint256 invalidBorrow = maxBorrow +
            bound(uint256(extraBorrowRaw), 1 ether, 50_000 ether);

        vm.prank(USER);
        lendingPool.depositToken(600_000 ether);

        uint256 expectedHealthFactor = ((collateralAmount * 1500) * PRECISION) /
            invalidBorrow;

        vm.startPrank(USER2);
        lendingPool.depositCollateral(collateralAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingPool.LendingPool__HealthFactorBroken.selector,
                expectedHealthFactor
            )
        );
        lendingPool.borrowToken(invalidBorrow);
        vm.stopPrank();
    }

    function testFuzz_RepayDebt_MultiUserFlowReducesExposure(
        uint96 liquidityRaw,
        uint96 collateralRaw,
        uint96 borrowRaw,
        uint96 repayRaw,
        uint32 warpRaw
    ) external {
        uint256 liquidity = bound(
            uint256(liquidityRaw),
            5_000 ether,
            300_000 ether
        );
        uint256 collateralAmount = bound(
            uint256(collateralRaw),
            1 ether,
            200 ether
        );
        uint256 maxBorrow = _min(liquidity, collateralAmount * 1500);
        uint256 borrowAmount = bound(uint256(borrowRaw), 100 ether, maxBorrow);
        uint256 repayAmount = bound(uint256(repayRaw), 1, borrowAmount);
        uint256 warpDt = bound(uint256(warpRaw), 1 hours, 90 days);

        vm.prank(USER);
        lendingPool.depositToken(liquidity);

        vm.startPrank(USER2);
        lendingPool.depositCollateral(collateralAmount);
        lendingPool.borrowToken(borrowAmount);
        vm.stopPrank();

        _warpAndRefreshOracle(warpDt);

        uint256 borrowerDebtBefore = lendingPool.getBorrowerDebt(USER2);
        uint256 borrowerUsdcBefore = usdc.balanceOf(USER2);
        uint256 poolUsdcBefore = usdc.balanceOf(address(lendingPool));

        vm.prank(USER2);
        lendingPool.repayDebt(repayAmount);

        uint256 borrowerDebtAfter = lendingPool.getBorrowerDebt(USER2);
        assertLt(borrowerDebtAfter, borrowerDebtBefore);
        assertEq(borrowerUsdcBefore - usdc.balanceOf(USER2), repayAmount);
        assertEq(
            usdc.balanceOf(address(lendingPool)) - poolUsdcBefore,
            repayAmount
        );
    }

    ///////////////////
    // Combo Paths
    ///////////////////

    function testFuzz_DepositCollateralAndBorrowToken_ComboPath(
        uint96 liquidityRaw,
        uint96 collateralRaw,
        uint96 borrowRaw
    ) external {
        uint256 liquidity = bound(
            uint256(liquidityRaw),
            1_000 ether,
            300_000 ether
        );
        uint256 collateralAmount = bound(
            uint256(collateralRaw),
            1 ether,
            200 ether
        );
        uint256 maxBorrow = _min(liquidity, collateralAmount * 1500);
        uint256 borrowAmount = bound(uint256(borrowRaw), 1, maxBorrow);

        vm.prank(USER);
        lendingPool.depositToken(liquidity);

        uint256 borrowerUsdcBefore = usdc.balanceOf(USER2);
        uint256 poolUsdcBefore = usdc.balanceOf(address(lendingPool));
        uint256 poolWethBefore = weth.balanceOf(address(lendingPool));

        vm.prank(USER2);
        lendingPool.depositCollateralAndBorrowToken(
            collateralAmount,
            borrowAmount
        );

        assertEq(usdc.balanceOf(USER2) - borrowerUsdcBefore, borrowAmount);
        assertEq(
            poolUsdcBefore - usdc.balanceOf(address(lendingPool)),
            borrowAmount
        );
        assertEq(
            weth.balanceOf(address(lendingPool)) - poolWethBefore,
            collateralAmount
        );
    }

    function testFuzz_RepayDebtAndRedeemCollateral_ComboPath(
        uint96 liquidityRaw,
        uint96 collateralRaw,
        uint96 borrowRaw,
        uint96 repayRaw,
        uint96 redeemRaw
    ) external {
        uint256 liquidity = bound(
            uint256(liquidityRaw),
            5_000 ether,
            300_000 ether
        );
        uint256 collateralAmount = bound(
            uint256(collateralRaw),
            2 ether,
            300 ether
        );
        uint256 maxBorrow = _min(liquidity, collateralAmount * 1200);
        uint256 borrowAmount = bound(uint256(borrowRaw), 100 ether, maxBorrow);
        uint256 repayAmount = bound(uint256(repayRaw), 1, borrowAmount);
        uint256 remainingDebt = borrowAmount - repayAmount;
        uint256 requiredCollateralAfterRepay = remainingDebt / 1500;
        uint256 maxRedeem = collateralAmount - requiredCollateralAfterRepay;
        uint256 redeemAmount = bound(uint256(redeemRaw), 1, maxRedeem);

        vm.prank(USER);
        lendingPool.depositToken(liquidity);

        vm.prank(USER2);
        lendingPool.depositCollateralAndBorrowToken(
            collateralAmount,
            borrowAmount
        );

        uint256 borrowerUsdcBefore = usdc.balanceOf(USER2);
        uint256 borrowerWethBefore = weth.balanceOf(USER2);

        vm.prank(USER2);
        lendingPool.repayDebtAndRedeemCollateral(repayAmount, redeemAmount);

        assertEq(borrowerUsdcBefore - usdc.balanceOf(USER2), repayAmount);
        assertEq(weth.balanceOf(USER2) - borrowerWethBefore, redeemAmount);
    }

    ///////////////////
    // Protocol Reserve
    ///////////////////

    function testFuzz_WithdrawProtocolReserves_OnlyOperatorCanWithdraw(
        uint96 liquidityRaw,
        uint96 borrowRaw,
        uint32 warpRaw,
        uint96 withdrawRaw
    ) external {
        uint256 liquidity = bound(
            uint256(liquidityRaw),
            10_000 ether,
            300_000 ether
        );
        uint256 borrowAmount = bound(
            uint256(borrowRaw),
            100 ether,
            _min(liquidity, 3_000 ether)
        );
        uint256 warpDt = bound(uint256(warpRaw), 1 days, 120 days);

        vm.prank(USER);
        lendingPool.depositToken(liquidity);

        vm.startPrank(USER2);
        lendingPool.depositCollateral(2 ether);
        lendingPool.borrowToken(borrowAmount);
        vm.stopPrank();

        uint256 borrowRate = _expectedBorrowRate(liquidity, borrowAmount);
        uint256 expectedBorrowInterest = _interest(
            borrowAmount,
            borrowRate,
            warpDt
        );
        uint256 expectedReserve = (expectedBorrowInterest * RESERVE_FACTOR) /
            PRECISION;
        vm.assume(expectedReserve > 0);

        _warpAndRefreshOracle(warpDt);

        vm.prank(USER2);
        lendingPool.repayDebt(1 ether);

        uint256 withdrawAmount = bound(
            uint256(withdrawRaw),
            1,
            expectedReserve
        );

        vm.prank(USER3);
        vm.expectRevert(LendingPool.LendingPool__CallerNotAuthorized.selector);
        lendingPool.withdrawProtocolReserves(USER3, withdrawAmount);

        uint256 operatorUsdcBefore = usdc.balanceOf(OPERATOR);
        vm.prank(OPERATOR);
        lendingPool.withdrawProtocolReserves(OPERATOR, withdrawAmount);

        assertEq(usdc.balanceOf(OPERATOR) - operatorUsdcBefore, withdrawAmount);
    }

    ///////////////////
    // Oracle Adversarial
    ///////////////////

    function testFuzz_BorrowToken_RevertsOnStaleOracle(
        uint96 liquidityRaw,
        uint96 collateralRaw,
        uint96 borrowRaw,
        uint32 staleByRaw
    ) external {
        uint256 liquidity = bound(
            uint256(liquidityRaw),
            2_000 ether,
            200_000 ether
        );
        uint256 collateralAmount = bound(
            uint256(collateralRaw),
            1 ether,
            100 ether
        );
        uint256 maxBorrow = _min(liquidity, collateralAmount * 1500);
        uint256 borrowAmount = bound(uint256(borrowRaw), 1, maxBorrow);
        uint256 staleBy = bound(uint256(staleByRaw), 3 hours + 1, 7 days);

        vm.prank(USER);
        lendingPool.depositToken(liquidity);

        vm.prank(USER2);
        lendingPool.depositCollateral(collateralAmount);

        vm.warp(block.timestamp + staleBy);

        vm.prank(USER2);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lendingPool.borrowToken(borrowAmount);
    }
}
