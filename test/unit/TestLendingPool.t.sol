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
import {FailingERC20} from "../mocks/FailingERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract TestLendingPool is Test, CodeConstant {
    uint256 private constant YEAR = 365 days;
    uint256 private constant HALF_YEAR = 365 days / 2;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant LIQUIDATION_BONUS = 5;
    uint256 private constant LIQUIDATION_PRECISION = 100;

    LendingPool lendingPool;
    HelperConfig helperConfig;
    address USER = makeAddr("user");
    address USER2 = makeAddr("user2");
    address USER3 = makeAddr("user3");
    FakeERC20 usdc;
    FakeERC20 weth;
    MockV3Aggregator priceFeed;
    address OPERATOR;

    event TokenDeposited(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event TokenBorrowed(address indexed user, uint256 amount);
    event TokenWithdrawn(address indexed user, uint256 amount);
    event CollateralRedeemed(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    function setUp() external {
        OPERATOR = makeAddr("operator");

        DeployLendingPool deployer = new DeployLendingPool();
        (lendingPool, helperConfig) = deployer.deploy(OPERATOR);
        address underlyingAssetAddr = lendingPool.getUnderlyingAssetAddress();
        address collateralAddr = lendingPool.getCollateralAddress();
        usdc = FakeERC20(underlyingAssetAddr);
        weth = FakeERC20(collateralAddr);

        (, , , , , , , address priceFeedAddr) = helperConfig.activeConfig();
        priceFeed = MockV3Aggregator(priceFeedAddr);

        usdc.mint(USER, 100000 ether);
        weth.mint(USER, 100000 ether);
        usdc.mint(USER2, 100000 ether);
        weth.mint(USER2, 100000 ether);
        usdc.mint(USER3, 100000 ether);
        weth.mint(USER3, 100000 ether);

        _approveMax(USER);
        _approveMax(USER2);
        _approveMax(USER3);
    }

    ///////////////////
    // Modifiers
    ///////////////////

    modifier depositedToken() {
        vm.prank(USER);
        lendingPool.depositToken(1000 ether);
        _;
    }

    modifier depositedCollateral() {
        vm.prank(USER);
        lendingPool.depositCollateral(1000 ether);
        _;
    }

    modifier borrowSetup() {
        vm.prank(USER);
        lendingPool.depositToken(1000 ether);

        vm.startPrank(USER2);
        lendingPool.depositCollateral(1 ether);
        lendingPool.borrowToken(100 ether);
        vm.stopPrank();
        _;
    }

    ///////////////////
    // Helpers
    ///////////////////

    function _approveMax(address actor) internal {
        vm.startPrank(actor);
        usdc.approve(address(lendingPool), type(uint256).max);
        weth.approve(address(lendingPool), type(uint256).max);
        vm.stopPrank();
    }

    function _approveMaxForPool(
        address actor,
        address pool,
        FakeERC20 underlying,
        FakeERC20 collateral
    ) internal {
        vm.startPrank(actor);
        underlying.approve(pool, type(uint256).max);
        collateral.approve(pool, type(uint256).max);
        vm.stopPrank();
    }

    function _approveMaxForPool(
        address actor,
        address pool,
        FailingERC20 underlying,
        FakeERC20 collateral
    ) internal {
        vm.startPrank(actor);
        underlying.approve(pool, type(uint256).max);
        collateral.approve(pool, type(uint256).max);
        vm.stopPrank();
    }

    function _approveMaxForPool(
        address actor,
        address pool,
        FakeERC20 underlying,
        FailingERC20 collateral
    ) internal {
        vm.startPrank(actor);
        underlying.approve(pool, type(uint256).max);
        collateral.approve(pool, type(uint256).max);
        vm.stopPrank();
    }

    function _deployCustomPool(
        address underlying,
        address collateral,
        address operator
    ) internal returns (LendingPool pool, MockV3Aggregator customPriceFeed) {
        customPriceFeed = new MockV3Aggregator(
            PRICE_FEED_DECIMALS,
            ETH_USD_PRICE
        );
        vm.prank(operator);
        pool = new LendingPool(
            underlying,
            collateral,
            BASE_RATE,
            SLOPE,
            BASE_RATE_AT_KINK,
            SLOPE_AT_KINK,
            RESERVE_FACTOR,
            address(customPriceFeed)
        );
    }

    function _warpAndRefreshOracle(uint256 timeToWarp) internal {
        vm.warp(block.timestamp + timeToWarp);
        priceFeed.updateAnswer(ETH_USD_PRICE);
    }

    function _warpAndSetOraclePrice(uint256 timeToWarp, int256 price) internal {
        vm.warp(block.timestamp + timeToWarp);
        priceFeed.updateAnswer(price);
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

    function _expectedLenderRate(
        uint256 totalLiquidity,
        uint256 totalBorrowed
    ) internal pure returns (uint256) {
        uint256 utilization = InterestLib.calculateUtilization(
            totalLiquidity,
            totalBorrowed
        );
        uint256 borrowRate = _expectedBorrowRate(totalLiquidity, totalBorrowed);
        return
            InterestLib.calculateLenderInterest(
                borrowRate,
                utilization,
                RESERVE_FACTOR
            );
    }

    function _interest(
        uint256 principal,
        uint256 rate,
        uint256 dt
    ) internal pure returns (uint256) {
        return InterestLib.calculateInterestAccrued(principal, rate, dt);
    }

    function _accruedByIndex(
        uint256 principal,
        uint256 rate,
        uint256 dt
    ) internal pure returns (uint256) {
        uint256 factor = InterestLib.calculateIndexUpdate(dt, rate);
        return (principal * factor) / PRECISION;
    }

    function _expectedLiquidationCollateral(
        uint256 debtToCover,
        int256 price
    ) internal pure returns (uint256) {
        uint256 tokenAmountFromDebtCovered = (debtToCover * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        return tokenAmountFromDebtCovered + bonusCollateral;
    }

    function _expectedPreviewRates(
        uint256 storedTotalLiquidity,
        uint256 storedTotalBorrowed,
        uint256 dt
    )
        internal
        pure
        returns (uint256 previewBorrowRate, uint256 previewLenderRate)
    {
        uint256 storedBorrowRate = _expectedBorrowRate(
            storedTotalLiquidity,
            storedTotalBorrowed
        );
        uint256 storedLenderRate = _expectedLenderRate(
            storedTotalLiquidity,
            storedTotalBorrowed
        );

        uint256 previewTotalBorrowed = storedTotalBorrowed +
            _interest(storedTotalBorrowed, storedBorrowRate, dt);
        uint256 previewTotalLiquidity = storedTotalLiquidity +
            _interest(storedTotalLiquidity, storedLenderRate, dt);

        previewBorrowRate = _expectedBorrowRate(
            previewTotalLiquidity,
            previewTotalBorrowed
        );
        previewLenderRate = _expectedLenderRate(
            previewTotalLiquidity,
            previewTotalBorrowed
        );
    }

    function _expectedPreviewBorrowerDebt(
        uint256 borrowerPrincipal,
        uint256 storedTotalLiquidity,
        uint256 storedTotalBorrowed,
        uint256 dt
    ) internal pure returns (uint256) {
        (uint256 previewBorrowRate, ) = _expectedPreviewRates(
            storedTotalLiquidity,
            storedTotalBorrowed,
            dt
        );
        return _accruedByIndex(borrowerPrincipal, previewBorrowRate, dt);
    }

    ///////////////////
    // Deposit Token Tests
    ///////////////////

    function testDepositMoney__UpdatesUserBalance() external {
        uint256 balanceBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        lendingPool.depositToken(1000 ether);

        uint256 balanceAfter = usdc.balanceOf(USER);
        assertEq(lendingPool.getDepositAmount(USER), 1000 ether);
        assertEq(balanceBefore - balanceAfter, 1000 ether);
        assertEq(lendingPool.getTotalLiquidity(), 1000 ether);
    }

    function testDepositToken__updatesBalanceWhenTheUserHasExisitingBalance()
        external
        borrowSetup
    {
        uint256 lenderRate = _expectedLenderRate(1000 ether, 100 ether);
        uint256 expectedUpdatedDeposit = _accruedByIndex(
            1000 ether,
            lenderRate,
            YEAR
        );
        uint256 expectedLiquidityInterest = _interest(
            1000 ether,
            lenderRate,
            YEAR
        );

        _warpAndRefreshOracle(YEAR);

        vm.prank(USER);
        lendingPool.depositToken(500 ether);

        assertEq(
            lendingPool.getDepositAmount(USER),
            expectedUpdatedDeposit + 500 ether
        );
        assertEq(
            lendingPool.getTotalLiquidity(),
            1500 ether + expectedLiquidityInterest
        );
    }

    function testDepositToken__updatesTotalLiquidity() external depositedToken {
        assertEq(lendingPool.getTotalLiquidity(), 1000 ether);
    }

    function testDepositToken__updatesTotalLiquidityAccountingForInterest()
        external
        depositedToken
        borrowSetup
    {
        vm.prank(USER3);
        lendingPool.depositToken(500 ether);

        uint256 lenderRate = _expectedLenderRate(2500 ether, 100 ether);
        uint256 expectedTotalLiquidity = 2501 ether +
            _interest(2500 ether, lenderRate, YEAR);

        _warpAndRefreshOracle(YEAR);

        vm.prank(USER);
        lendingPool.depositToken(1 ether);

        assertEq(lendingPool.getTotalLiquidity(), expectedTotalLiquidity);
        assertEq(
            lendingPool.getDepositAmount(USER),
            _accruedByIndex(2000 ether, lenderRate, YEAR) + 1 ether
        );
        assertEq(
            lendingPool.getDepositAmount(USER3),
            _accruedByIndex(500 ether, lenderRate, YEAR)
        );
    }

    ///////////////////
    // Deposit Collateral Tests
    ///////////////////

    function testDepositCollateral__updatesUserCollateral()
        external
        depositedCollateral
    {
        uint256 collateralValue = lendingPool.getCollateralValue(USER);
        uint256 depositedAmountUsd = lendingPool.getUsdValue(1000 ether);
        assertEq(collateralValue, depositedAmountUsd);
        assertEq(weth.balanceOf(address(lendingPool)), 1000 ether);
    }

    ///////////////////
    // Withdraw Token Tests
    ///////////////////

    function testWithdrawToken__UpdatesUserBalance() external depositedToken {
        uint256 usdcBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        lendingPool.withdrawToken(400 ether);

        uint256 depositAfter = lendingPool.getDepositAmount(USER);
        uint256 usdcAfter = usdc.balanceOf(USER);

        assertEq(depositAfter, 600 ether);
        assertEq(usdcAfter - usdcBefore, 400 ether);
        assertEq(lendingPool.getTotalLiquidity(), 600 ether);
    }

    function testWithdrawToken__UserCanWithdrawWithInterest()
        external
        depositedToken
        borrowSetup
    {
        uint256 lenderRate = _expectedLenderRate(2000 ether, 100 ether);
        uint256 expectedAccruedDeposit = _accruedByIndex(
            2000 ether,
            lenderRate,
            YEAR
        );
        uint256 expectedInterest = _interest(2000 ether, lenderRate, YEAR);

        _warpAndRefreshOracle(YEAR);

        uint256 usdcBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        lendingPool.withdrawToken(1000 ether);

        assertEq(
            lendingPool.getDepositAmount(USER),
            expectedAccruedDeposit - 1000 ether
        );
        assertEq(
            lendingPool.getTotalLiquidity(),
            1000 ether + expectedInterest
        );
        assertEq(usdc.balanceOf(USER) - usdcBefore, 1000 ether);
    }

    function testWithdrawToken__UserCantWithdrawMoreThanTheyDeposited()
        external
        depositedToken
    {
        vm.prank(USER);
        vm.expectRevert();
        lendingPool.withdrawToken(1001 ether);
    }

    function testWithdrawToken__TotalBorrowedIncreaseWithInterestAccrued()
        external
        borrowSetup
    {
        vm.startPrank(USER3);
        lendingPool.depositCollateral(1 ether);
        lendingPool.borrowToken(50 ether);
        vm.stopPrank();

        uint256 borrowRate = _expectedBorrowRate(1000 ether, 150 ether);
        uint256 expectedTotalBorrowed = 150 ether +
            _interest(150 ether, borrowRate, YEAR);

        _warpAndRefreshOracle(YEAR);

        assertEq(lendingPool.getTotalBorrowed(), expectedTotalBorrowed);
    }

    function testWithdrawToken__RevertsWhenLiquidityNotAvailable()
        external
        borrowSetup
    {
        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__NotEnoughLiquidityAvailable.selector
        );
        lendingPool.withdrawToken(1000 ether);
    }

    function testWithdrawToken__TotalLiquidityDoesntUnderflow()
        external
        depositedToken
    {
        vm.prank(USER);
        lendingPool.withdrawToken(1000 ether);

        assertEq(lendingPool.getTotalLiquidity(), 0);
    }

    ///////////////////
    // Borrow Token Tests
    ///////////////////

    function testBorrowToken__RevertsIfHealthFactorBroken()
        external
        depositedToken
    {
        vm.prank(USER);
        lendingPool.depositToken(1000 ether);

        uint256 collateralValueInUsd = lendingPool.getUsdValue(1 ether);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * 75) /
            100;
        uint256 expectedHealthFactor = (collateralAdjustedForThreshold *
            PRECISION) / 1600 ether;

        vm.startPrank(USER2);
        lendingPool.depositCollateral(1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingPool.LendingPool__HealthFactorBroken.selector,
                expectedHealthFactor
            )
        );
        lendingPool.borrowToken(1600 ether);
        vm.stopPrank();
    }

    function testBorrowToken__RevertsWhenLiquidityNotAvailable()
        external
        depositedToken
    {
        vm.startPrank(USER2);
        lendingPool.depositCollateral(10 ether);
        vm.expectRevert(
            LendingPool.LendingPool__NotEnoughLiquidityAvailable.selector
        );
        lendingPool.borrowToken(1001 ether);
        vm.stopPrank();
    }

    function testBorrowToken__transfersTokenToUser() external borrowSetup {
        assertEq(usdc.balanceOf(USER2), 100100 ether);
        assertEq(usdc.balanceOf(address(lendingPool)), 900 ether);
    }

    function testBorrowToken__increaseLiquidityIndex() external borrowSetup {
        uint256 borrowRate = _expectedBorrowRate(1000 ether, 100 ether);
        uint256 expectedIndex = InterestLib.calculateIndexUpdate(
            YEAR,
            borrowRate
        );
        uint256 expectedTotalBorrowed = 110 ether +
            _interest(100 ether, borrowRate, YEAR);

        _warpAndRefreshOracle(YEAR);

        vm.prank(USER2);
        lendingPool.borrowToken(10 ether);

        LendingPool.InterestIndex memory indexAfter = lendingPool
            .getBorrowIndex();
        assertEq(indexAfter.index, expectedIndex);
        assertEq(
            lendingPool.getBorrowerDebt(USER2),
            _accruedByIndex(100 ether, borrowRate, YEAR) + 10 ether
        );
        assertEq(lendingPool.getTotalBorrowed(), expectedTotalBorrowed);
    }

    ///////////////////
    // Repay Debt Tests
    ///////////////////

    function testRepayDebt__decreasesUserDebt() external borrowSetup {
        vm.startPrank(USER3);
        lendingPool.depositCollateral(1 ether);
        lendingPool.borrowToken(50 ether);
        vm.stopPrank();

        uint256 borrowRate = _expectedBorrowRate(1000 ether, 150 ether);
        uint256 expectedTotalBorrowedBeforeRepay = 150 ether +
            _interest(150 ether, borrowRate, HALF_YEAR);

        _warpAndRefreshOracle(HALF_YEAR);

        vm.prank(USER2);
        lendingPool.repayDebt(50 ether);

        assertEq(
            lendingPool.getBorrowerDebt(USER2),
            _accruedByIndex(100 ether, borrowRate, HALF_YEAR) - 50 ether
        );
        assertEq(
            lendingPool.getTotalBorrowed(),
            expectedTotalBorrowedBeforeRepay - 50 ether
        );
    }

    function testRepayDebt__totalBorrowedDoesntUnderflow()
        external
        borrowSetup
    {
        vm.prank(USER2);
        lendingPool.repayDebt(100 ether);

        assertEq(lendingPool.getTotalBorrowed(), 0);
    }

    function testRepayDebt__UpdatesBalancesOfProtocolAndUser()
        external
        borrowSetup
    {
        uint256 borrowRate = _expectedBorrowRate(1000 ether, 100 ether);
        uint256 expectedBorrowedAfterRepay = 50 ether +
            _interest(100 ether, borrowRate, YEAR);

        _warpAndRefreshOracle(YEAR);

        uint256 user2UsdcBefore = usdc.balanceOf(USER2);
        uint256 poolUsdcBefore = usdc.balanceOf(address(lendingPool));

        vm.prank(USER2);
        lendingPool.repayDebt(50 ether);

        uint256 user2UsdcAfter = usdc.balanceOf(USER2);
        uint256 poolUsdcAfter = usdc.balanceOf(address(lendingPool));

        assertEq(user2UsdcBefore - user2UsdcAfter, 50 ether);
        assertEq(poolUsdcAfter - poolUsdcBefore, 50 ether);
        assertEq(lendingPool.getTotalBorrowed(), expectedBorrowedAfterRepay);
    }

    function testRepayDebt__UserCantPayBackMoreThanDebt() external borrowSetup {
        vm.prank(USER2);
        vm.expectRevert();
        lendingPool.repayDebt(200 ether);
    }

    ///////////////////
    // Liquidation Tests
    ///////////////////

    function testLiquidation__ReducesBorrowersDebtAndTransferCollateralToRepayerWithBonus()
        external
        borrowSetup
    {
        uint256 borrowRate = _expectedBorrowRate(1000 ether, 100 ether);
        uint256 expectedDebtBeforeStateUpdate = _accruedByIndex(
            100 ether,
            borrowRate,
            YEAR
        );
        uint256 expectedDebtBeforeView = _expectedPreviewBorrowerDebt(
            100 ether,
            1000 ether,
            100 ether,
            YEAR
        );
        uint256 debtToCover = 61 ether;
        int256 liquidationPrice = 120e8;
        uint256 expectedCollateralToRedeem = _expectedLiquidationCollateral(
            debtToCover,
            liquidationPrice
        );

        _warpAndSetOraclePrice(YEAR, liquidationPrice);

        uint256 debtBefore = lendingPool.getBorrowerDebt(USER2);
        uint256 liquidatorWethBefore = weth.balanceOf(USER);
        uint256 liquidatorUsdcBefore = usdc.balanceOf(USER);

        vm.prank(USER);
        lendingPool.liquidate(USER2, debtToCover);

        uint256 debtAfter = lendingPool.getBorrowerDebt(USER2);
        uint256 liquidatorWethAfter = weth.balanceOf(USER);
        uint256 liquidatorUsdcAfter = usdc.balanceOf(USER);

        assertEq(debtBefore, expectedDebtBeforeView);
        assertEq(debtAfter, expectedDebtBeforeStateUpdate - debtToCover);
        assertEq(
            liquidatorWethAfter - liquidatorWethBefore,
            expectedCollateralToRedeem
        );
        assertEq(liquidatorUsdcBefore - liquidatorUsdcAfter, debtToCover);
        assertEq(
            lendingPool.getTotalBorrowed(),
            expectedDebtBeforeStateUpdate - debtToCover
        );
        assertGe(lendingPool.getHealthFactor(USER2), PRECISION);
    }

    function testLiquidation__RevertsIfHealthFactorNotImproved()
        external
        borrowSetup
    {
        _warpAndSetOraclePrice(YEAR, 100e8);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__HealthFactorNotImproved.selector
        );
        lendingPool.liquidate(USER2, 1 ether);
    }

    function testLiquidation__RevertsIfHealthFactorOk() external borrowSetup {
        vm.prank(USER);
        vm.expectRevert(LendingPool.LendingPool__HealthFactorOk.selector);
        lendingPool.liquidate(USER2, 50 ether);
    }

    ///////////////////
    // Combo Function Tests
    ///////////////////

    function testDepositCollateralAndBorrowToken() external depositedToken {
        uint256 user2UsdcBefore = usdc.balanceOf(USER2);

        vm.prank(USER2);
        lendingPool.depositCollateralAndBorrowToken(1 ether, 100 ether);

        assertEq(
            lendingPool.getCollateralValue(USER2),
            lendingPool.getUsdValue(1 ether)
        );
        assertEq(lendingPool.getBorrowerDebt(USER2), 100 ether);
        assertEq(usdc.balanceOf(USER2) - user2UsdcBefore, 100 ether);
        assertEq(lendingPool.getTotalBorrowed(), 100 ether);
    }

    function testRepayDebtAndRedeemCollateral() external borrowSetup {
        uint256 user2WethBefore = weth.balanceOf(USER2);

        vm.prank(USER2);
        lendingPool.repayDebtAndRedeemCollateral(100 ether, 0.5 ether);

        assertEq(lendingPool.getBorrowerDebt(USER2), 0);
        assertEq(weth.balanceOf(USER2) - user2WethBefore, 0.5 ether);
        assertEq(
            lendingPool.getCollateralValue(USER2),
            lendingPool.getUsdValue(0.5 ether)
        );
    }

    ///////////////////
    // Protocol Reserve Tests
    ///////////////////

    function testWithdrawProtocolReservers__RevertsIfNotAuthorized()
        external
        borrowSetup
    {
        uint256 borrowRate = _expectedBorrowRate(1000 ether, 100 ether);
        uint256 expectedBorrowInterest = _interest(100 ether, borrowRate, YEAR);
        uint256 expectedReserve = (expectedBorrowInterest * RESERVE_FACTOR) /
            PRECISION;

        _warpAndRefreshOracle(YEAR);

        vm.prank(USER2);
        lendingPool.repayDebt(10 ether);

        assertEq(
            lendingPool.getLiquidityAvailable(),
            910 ether - expectedReserve
        );

        vm.prank(USER);
        vm.expectRevert(LendingPool.LendingPool__CallerNotAuthorized.selector);
        lendingPool.withdrawProtocolReserves(USER, 1);
    }

    function testWithdrawProtocolReservers__TransfersTheReserves()
        external
        borrowSetup
    {
        uint256 borrowRate = _expectedBorrowRate(1000 ether, 100 ether);
        uint256 expectedBorrowInterest = _interest(100 ether, borrowRate, YEAR);
        uint256 expectedReserve = (expectedBorrowInterest * RESERVE_FACTOR) /
            PRECISION;

        _warpAndRefreshOracle(YEAR);

        vm.prank(USER2);
        lendingPool.repayDebt(10 ether);

        uint256 operatorUsdcBefore = usdc.balanceOf(OPERATOR);

        vm.prank(OPERATOR);
        lendingPool.withdrawProtocolReserves(OPERATOR, expectedReserve);

        assertEq(
            usdc.balanceOf(OPERATOR) - operatorUsdcBefore,
            expectedReserve
        );
        assertEq(
            lendingPool.getLiquidityAvailable(),
            910 ether - expectedReserve
        );

        vm.prank(OPERATOR);
        vm.expectRevert();
        lendingPool.withdrawProtocolReserves(OPERATOR, 1);
    }

    ///////////////////
    // Event Tests
    ///////////////////

    function testEvents__DepositTokenEmitsTokenDeposited() external {
        vm.expectEmit(true, false, false, true, address(lendingPool));
        emit TokenDeposited(USER, 321 ether);

        vm.prank(USER);
        lendingPool.depositToken(321 ether);
    }

    function testEvents__DepositCollateralEmitsCollateralDeposited() external {
        vm.expectEmit(true, false, false, true, address(lendingPool));
        emit CollateralDeposited(USER2, 2 ether);

        vm.prank(USER2);
        lendingPool.depositCollateral(2 ether);
    }

    function testEvents__BorrowTokenEmitsTokenBorrowed()
        external
        depositedToken
    {
        vm.prank(USER2);
        lendingPool.depositCollateral(1 ether);

        vm.expectEmit(true, false, false, true, address(lendingPool));
        emit TokenBorrowed(USER2, 100 ether);

        vm.prank(USER2);
        lendingPool.borrowToken(100 ether);
    }

    function testEvents__WithdrawTokenEmitsTokenWithdrawn()
        external
        depositedToken
    {
        vm.expectEmit(true, false, false, true, address(lendingPool));
        emit TokenWithdrawn(USER, 250 ether);

        vm.prank(USER);
        lendingPool.withdrawToken(250 ether);
    }

    function testEvents__RedeemCollateralEmitsCollateralRedeemed() external {
        vm.prank(USER2);
        lendingPool.depositCollateral(1 ether);

        vm.expectEmit(true, true, false, true, address(lendingPool));
        emit CollateralRedeemed(USER2, USER2, 0.4 ether);

        vm.prank(USER2);
        lendingPool.redeemCollateral(0.4 ether);
    }

    function testEvents__LiquidationEmitsCollateralRedeemed()
        external
        borrowSetup
    {
        uint256 debtToCover = 61 ether;
        int256 liquidationPrice = 120e8;
        uint256 expectedCollateralToRedeem = _expectedLiquidationCollateral(
            debtToCover,
            liquidationPrice
        );

        _warpAndSetOraclePrice(YEAR, liquidationPrice);

        vm.expectEmit(true, true, false, true, address(lendingPool));
        emit CollateralRedeemed(USER2, USER, expectedCollateralToRedeem);

        vm.prank(USER);
        lendingPool.liquidate(USER2, debtToCover);
    }

    ///////////////////
    // Getter Tests
    ///////////////////

    function testGetters__AddressesAndInitialState() external view {
        assertEq(lendingPool.getUnderlyingAssetAddress(), address(usdc));
        assertEq(lendingPool.getCollateralAddress(), address(weth));

        LendingPool.InterestIndex memory liquidityIndex = lendingPool
            .getLiquidityIndex();
        LendingPool.InterestIndex memory borrowerIndex = lendingPool
            .getBorrowIndex();

        assertEq(liquidityIndex.index, PRECISION);
        assertEq(borrowerIndex.index, PRECISION);
        assertEq(lendingPool.getTotalLiquidity(), 0);
        assertEq(lendingPool.getTotalBorrowed(), 0);
        assertEq(lendingPool.getDepositAmount(USER), 0);
        assertEq(lendingPool.getBorrowerDebt(USER2), 0);
        assertEq(lendingPool.getCollateralValue(USER3), 0);
    }

    function testGetters__ConversionHelpers() external view {
        assertEq(lendingPool.getUsdValue(1 ether), 2000 ether);
        assertEq(lendingPool.getTokenAmountFromUsd(2000 ether), 1 ether);
        assertEq(lendingPool.getTokenAmountFromUsd(1000 ether), 0.5 ether);
    }

    function testGetters__HealthFactorIsMaxWhenNoDebt() external {
        vm.prank(USER2);
        lendingPool.depositCollateral(3 ether);

        assertEq(lendingPool.getHealthFactor(USER2), type(uint256).max);
    }

    function testGetters__LenderInterestRateMatchesFormula()
        external
        borrowSetup
    {
        assertEq(
            lendingPool.getLenderInterestRate(),
            _expectedLenderRate(1000 ether, 100 ether)
        );
    }

    function testGetters__PreviewIndexesFollowModelWhenNoBorrows()
        external
        depositedToken
    {
        _warpAndRefreshOracle(2 days);

        LendingPool.InterestIndex memory previewLiquidityIndex = lendingPool
            .previewCurrentLiquidityIndex();
        LendingPool.InterestIndex memory previewBorrowerIndex = lendingPool
            .previewCurrentBorrowerIndex();
        uint256 expectedBorrowerIndex = InterestLib.calculateIndexUpdate(
            2 days,
            BASE_RATE
        );

        assertEq(previewLiquidityIndex.index, PRECISION);
        assertEq(previewBorrowerIndex.index, expectedBorrowerIndex);
        assertEq(previewLiquidityIndex.lastUpdate, block.timestamp);
        assertEq(previewBorrowerIndex.lastUpdate, block.timestamp);
    }

    function testGetters__PreviewIndexesIncreaseWithUtilization()
        external
        borrowSetup
    {
        _warpAndRefreshOracle(YEAR);

        (
            uint256 previewBorrowRate,
            uint256 previewLenderRate
        ) = _expectedPreviewRates(1000 ether, 100 ether, YEAR);

        uint256 expectedPreviewBorrowerIndex = InterestLib.calculateIndexUpdate(
            YEAR,
            previewBorrowRate
        );
        uint256 expectedPreviewLiquidityIndex = InterestLib
            .calculateIndexUpdate(YEAR, previewLenderRate);

        assertEq(
            lendingPool.previewCurrentBorrowerIndex().index,
            expectedPreviewBorrowerIndex
        );
        assertEq(
            lendingPool.previewCurrentLiquidityIndex().index,
            expectedPreviewLiquidityIndex
        );
    }

    function testGetters__LiquidityAvailableIsBalanceMinusReserve()
        external
        borrowSetup
    {
        uint256 borrowRate = _expectedBorrowRate(1000 ether, 100 ether);
        uint256 expectedBorrowInterest = _interest(100 ether, borrowRate, YEAR);
        uint256 expectedReserve = (expectedBorrowInterest * RESERVE_FACTOR) /
            PRECISION;

        _warpAndRefreshOracle(YEAR);

        vm.prank(USER2);
        lendingPool.repayDebt(1 ether);

        uint256 expectedAvailableLiquidity = usdc.balanceOf(
            address(lendingPool)
        ) - expectedReserve;
        assertEq(
            lendingPool.getLiquidityAvailable(),
            expectedAvailableLiquidity
        );
    }

    ///////////////////
    // Revert Guard Tests
    ///////////////////

    function testReverts__AmountMustBeMoreThanZeroAcrossAllEntryPoints()
        external
    {
        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.depositToken(0);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.withdrawToken(0);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.depositCollateral(0);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.borrowToken(0);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.repayDebt(0);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.redeemCollateral(0);

        vm.prank(USER);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.liquidate(USER2, 0);

        vm.prank(OPERATOR);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.withdrawProtocolReserves(OPERATOR, 0);
    }

    function testReverts__ComboFunctionsPropagateAmountMustBeMoreThanZero()
        external
    {
        vm.prank(USER2);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.depositCollateralAndBorrowToken(0, 1 ether);

        vm.prank(USER2);
        vm.expectRevert(
            LendingPool.LendingPool__AmountMustBeMoreThanZero.selector
        );
        lendingPool.repayDebtAndRedeemCollateral(0, 1 ether);
    }

    ///////////////////
    // Oracle Edge Case Tests
    ///////////////////

    function testOracle__StalePriceRevertsOracleDependentFunctions()
        external
        depositedToken
    {
        vm.prank(USER2);
        lendingPool.depositCollateral(1 ether);

        vm.warp(block.timestamp + 3 hours + 1);

        vm.prank(USER2);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lendingPool.borrowToken(1 ether);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lendingPool.getUsdValue(1 ether);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lendingPool.getTokenAmountFromUsd(100 ether);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lendingPool.getCollateralValue(USER2);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        lendingPool.getHealthFactor(USER2);
    }

    ///////////////////
    // Adversarial State Tests
    ///////////////////

    function testBorrowToken__AllowsExactlyOneHealthFactor()
        external
        depositedToken
    {
        vm.prank(USER);
        lendingPool.depositToken(1000 ether);

        vm.startPrank(USER2);
        lendingPool.depositCollateral(1 ether);
        lendingPool.borrowToken(1500 ether);
        vm.stopPrank();

        assertEq(lendingPool.getHealthFactor(USER2), PRECISION);
    }

    function testRedeemCollateral__RevertsWhenHealthFactorWouldBreak()
        external
        borrowSetup
    {
        uint256 expectedHealthFactor = (75 ether * PRECISION) / 100 ether;

        vm.prank(USER2);
        vm.expectRevert(
            abi.encodeWithSelector(
                LendingPool.LendingPool__HealthFactorBroken.selector,
                expectedHealthFactor
            )
        );
        lendingPool.redeemCollateral(0.95 ether);
    }

    function testLiquidation__RevertsWhenDebtToCoverRequiresMoreCollateralThanExists()
        external
        borrowSetup
    {
        _warpAndSetOraclePrice(YEAR, 120e8);

        vm.prank(USER);
        vm.expectRevert();
        lendingPool.liquidate(USER2, 200 ether);
    }

    ///////////////////
    // Transfer Failure Revert Tests
    ///////////////////

    function testTransferFailed__DepositTokenRevertsWhenUnderlyingTransferFromFails()
        external
    {
        address customOperator = makeAddr("customOperator");
        FailingERC20 failingUnderlying = new FailingERC20("fUSDC", "fUSDC");
        FakeERC20 normalCollateral = new FakeERC20("fWETH", "fWETH");
        (LendingPool customPool, ) = _deployCustomPool(
            address(failingUnderlying),
            address(normalCollateral),
            customOperator
        );

        failingUnderlying.mint(USER, 1000 ether);
        normalCollateral.mint(USER, 1000 ether);
        _approveMaxForPool(
            USER,
            address(customPool),
            failingUnderlying,
            normalCollateral
        );

        failingUnderlying.setFailTransferFrom(true);

        vm.prank(USER);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.depositToken(1 ether);
    }

    function testTransferFailed__WithdrawTokenAndBorrowTokenRevertWhenUnderlyingTransferFails()
        external
    {
        address customOperator = makeAddr("customOperator");
        FailingERC20 failingUnderlying = new FailingERC20("fUSDC", "fUSDC");
        FakeERC20 normalCollateral = new FakeERC20("fWETH", "fWETH");
        (LendingPool customPool, ) = _deployCustomPool(
            address(failingUnderlying),
            address(normalCollateral),
            customOperator
        );

        failingUnderlying.mint(USER, 2000 ether);
        normalCollateral.mint(USER2, 2 ether);
        _approveMaxForPool(
            USER,
            address(customPool),
            failingUnderlying,
            normalCollateral
        );
        _approveMaxForPool(
            USER2,
            address(customPool),
            failingUnderlying,
            normalCollateral
        );

        vm.prank(USER);
        customPool.depositToken(1500 ether);

        failingUnderlying.setFailTransfer(true);

        vm.prank(USER);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.withdrawToken(1 ether);

        vm.prank(USER2);
        customPool.depositCollateral(1 ether);

        vm.prank(USER2);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.borrowToken(100 ether);
    }

    function testTransferFailed__RepayDebtAndWithdrawReserveRevertOnUnderlyingFailures()
        external
    {
        address customOperator = makeAddr("customOperator");
        FailingERC20 failingUnderlying = new FailingERC20("fUSDC", "fUSDC");
        FakeERC20 normalCollateral = new FakeERC20("fWETH", "fWETH");
        (
            LendingPool customPool,
            MockV3Aggregator customFeed
        ) = _deployCustomPool(
                address(failingUnderlying),
                address(normalCollateral),
                customOperator
            );

        failingUnderlying.mint(USER, 2000 ether);
        failingUnderlying.mint(USER2, 200 ether);
        normalCollateral.mint(USER2, 2 ether);
        _approveMaxForPool(
            USER,
            address(customPool),
            failingUnderlying,
            normalCollateral
        );
        _approveMaxForPool(
            USER2,
            address(customPool),
            failingUnderlying,
            normalCollateral
        );

        vm.prank(USER);
        customPool.depositToken(1500 ether);

        vm.startPrank(USER2);
        customPool.depositCollateral(1 ether);
        customPool.borrowToken(100 ether);
        vm.stopPrank();

        failingUnderlying.setFailTransferFrom(true);
        vm.prank(USER2);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.repayDebt(1 ether);

        failingUnderlying.setFailTransferFrom(false);
        vm.warp(block.timestamp + YEAR);
        customFeed.updateAnswer(ETH_USD_PRICE);
        vm.prank(USER2);
        customPool.repayDebt(1 ether);

        failingUnderlying.setFailTransfer(true);
        vm.prank(customOperator);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.withdrawProtocolReserves(customOperator, 1);
    }

    function testTransferFailed__DepositAndRedeemCollateralRevertOnCollateralFailures()
        external
    {
        address customOperator = makeAddr("customOperator");
        FakeERC20 normalUnderlying = new FakeERC20("fUSDC", "fUSDC");
        FailingERC20 failingCollateral = new FailingERC20("fWETH", "fWETH");
        (LendingPool customPool, ) = _deployCustomPool(
            address(normalUnderlying),
            address(failingCollateral),
            customOperator
        );

        normalUnderlying.mint(USER, 2000 ether);
        failingCollateral.mint(USER, 2 ether);
        failingCollateral.mint(USER2, 2 ether);
        _approveMaxForPool(
            USER,
            address(customPool),
            normalUnderlying,
            failingCollateral
        );
        _approveMaxForPool(
            USER2,
            address(customPool),
            normalUnderlying,
            failingCollateral
        );

        failingCollateral.setFailTransferFrom(true);
        vm.prank(USER2);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.depositCollateral(1 ether);

        failingCollateral.setFailTransferFrom(false);
        vm.prank(USER);
        customPool.depositCollateral(1 ether);

        failingCollateral.setFailTransfer(true);
        vm.prank(USER);
        vm.expectRevert(LendingPool.LendingPool__TransferFailed.selector);
        customPool.redeemCollateral(0.2 ether);
    }
}
