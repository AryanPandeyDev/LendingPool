//SPDX-License-Identifier:MIT

pragma solidity ^0.8.24;

import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {DeployLendingPool} from "../../script/DeployLendingPool.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {FakeERC20} from "../mocks/FakeERC20.sol";

contract TestLendingPool is Test {
    LendingPool lendingPool;
    HelperConfig helperConfig;
    address USER = makeAddr("user");
    address USER2 = makeAddr("user2");
    FakeERC20 usdc;
    FakeERC20 weth;

    function setUp() external {
        DeployLendingPool deployer = new DeployLendingPool();
        (lendingPool, helperConfig) = deployer.run();
        address underlyingAssetAddr = lendingPool.getUnderlyingAssetAddress();
        address collateralAddr = lendingPool.getCollateralAddress();
        usdc = FakeERC20(underlyingAssetAddr);
        weth = FakeERC20(collateralAddr);
        usdc.mint(USER, 10000 ether);
        weth.mint(USER, 10000 ether);
    }

    modifier depositedToken() {
        vm.startPrank(USER);
        usdc.approve(address(lendingPool), 1000 ether);
        lendingPool.depositToken(1000 ether);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        weth.approve(address(lendingPool), 1000 ether);
        lendingPool.depositCollateral(1000 ether);
        vm.stopPrank();
        _;
    }

    //deposit money
    function testDepositMoney__UpdatesUserBalance() external {
        uint256 balanceBefore = usdc.balanceOf(USER);
        vm.startPrank(USER);
        usdc.approve(address(lendingPool), 1000 ether);
        lendingPool.depositToken(1000 ether);
        vm.stopPrank();
        uint256 balance = lendingPool.getDepositAmount(USER);
        uint256 balanceAfter = usdc.balanceOf(USER);
        assert(balance == 1000 ether);
        assert(balanceBefore - balanceAfter == 1000 ether);
    }

    function testDepositToken__updatesBalanceWhenTheUserHasExisitingBalance()
        external
        depositedToken
    {}

    function testDepositToken__updatesTotalLiquidity() external depositedToken {
        uint256 totalLiquidity = lendingPool.getTotalLiquidity();
        assert(totalLiquidity == 1000 ether);
    }

    //deposit collateral
    function testDepositCollateral__updatesUserCollateral()
        external
        depositedCollateral
    {
        uint256 collateral = lendingPool.getCollateralValue(USER);
        uint256 depositedAmount = lendingPool.getUsdValue(1000 ether);
        assert(collateral == depositedAmount);
    }

    function testWithdrawToken__UpdatesUserBalance() external depositedToken {}

    function testWithdrawToken__UserCanWithdrawWithInterest()
        external
        depositedToken
    {
        // use warp time and also make another user borrow to change the liqidity index
        // then check if the amount user deposited they can withdraw with interest gained
    }

    function testWithdrawToken__UserCantWithdrawMoreThanTheyDeposited()
        external
        depositedToken
    {}

    function testWithdrawToken__TotalBorrowedIncreaseWithInterestAccured()
        external
        depositedToken
    {
        //make sure to warp time and actually stimulate the interest building up
    }

    function testWithdrawToken__RevertsWhenLiquidityNotAvailable()
        external
        depositedToken
    {}

    function testWithdrawToken__TotalLiquidityDoesntUnderflow() external {}

    function testBorrowToken__RevertsIfHealthFactorBroken() external {}

    function testBorrowToken__RevertsWhenLiquidityNotAvailable() external {}

    function testBorrowToken__transfersTokenToUser() external {}

    function testBorrowToken__increaseLiquidityIndex() external {
        //make sure to warp time to test
    }

    function testRepayDebt__decreasesUserDebt() external {}

    function testRepayDebt__totalBorrowedDoesntUnderflow() external {}

    function testRepayDebt__UpdatesBalancesOfProtocolAndUser() external {}

    function testRepayDebt__UserCantPayBackMoreThanDebt() external {}

    function testLiquidation__ReducesBorrowersDebtAndTransferCollateralToRepayerWithBonus()
        external
    {}

    function testLiquidation__RevertsIfHealthFactorNotImproved() external {}

    function testLiquidation__RevertsIfHealthFactorOk() external {}
}
