// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestLib} from "./libraries/InterestLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract LendingPool is ReentrancyGuard {
    //errors
    error LendingPool__AmountMustBeMoreThanZero();
    error LendingPool__TransferFailed();
    error LendingPool__NotEnoughLiquidityAvailable();
    error LendingPool__NotEnoughCollateral();
    error LendingPool__HealthFactorBroken(uint256 healthFactor);
    error LendingPool__HealthFactorOk();
    error LendingPool__HealthFactorNotImproved();
    error LendingPool__CallerNotAuthorized();

    //types
    using OracleLib for AggregatorV3Interface;

    //state variables
    mapping(address lender => LenderBalance) private s_lender;
    InterestIndex private s_liquidityIndex;
    mapping(address borrower => BorrowerBalance) private s_borrower;
    InterestIndex private s_borrowerIndex;
    uint256 private s_totalLiquidity;
    uint256 private s_totalBorrowed;
    uint256 private s_protocolReserve;
    uint256 private immutable i_baseRate;
    uint256 private immutable i_slope;
    uint256 private immutable i_baseRateAtKink;
    uint256 private immutable i_slopeAtKink;
    uint256 private immutable i_reserveFactor;
    address private immutable i_collateralPriceFeedAddress;
    address private immutable i_underlyingAssetAddress;
    address private immutable i_collateralAddress;
    address private immutable i_protocolOperator;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant STARTING_LIQUIDITY_INDEX = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 75;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 5;

    //events
    event TokenDeposited(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event TokenBorrowed(address indexed user, uint256 amount);
    event TokenWithdrawn(address indexed user, uint256 amount);
    event CollateralRedeemed(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    //structs
    struct LenderBalance {
        uint256 amount;
        uint256 index;
    }

    struct BorrowerBalance {
        uint256 debt;
        uint256 collateral;
        uint256 index;
    }

    struct InterestIndex {
        uint256 index;
        uint256 lastUpdate;
    }

    constructor(
        address _underlyingAssetAddress,
        address _collateralAddress,
        uint256 _baseRate,
        uint256 _slope,
        uint256 baseRateAtKink,
        uint256 slopeAtKink,
        uint256 reserveFactor,
        address _collateralPriceFeedAddress
    ) {
        i_underlyingAssetAddress = _underlyingAssetAddress;
        i_collateralAddress = _collateralAddress;
        i_baseRate = _baseRate;
        i_slope = _slope;
        i_baseRateAtKink = baseRateAtKink;
        i_slopeAtKink = slopeAtKink;
        i_reserveFactor = reserveFactor;
        s_liquidityIndex = InterestIndex({
            index: STARTING_LIQUIDITY_INDEX,
            lastUpdate: block.timestamp
        });
        s_borrowerIndex = InterestIndex({
            index: STARTING_LIQUIDITY_INDEX,
            lastUpdate: block.timestamp
        });
        i_collateralPriceFeedAddress = _collateralPriceFeedAddress;
        i_protocolOperator = msg.sender;
    }

    ///////////////////
    // Modifiers
    ///////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingPool__AmountMustBeMoreThanZero();
        }
        _;
    }

    modifier liquidityAvailable(uint256 amount) {
        if (amount > getLiquidityAvailable()) {
            revert LendingPool__NotEnoughLiquidityAvailable();
        }
        _;
    }

    modifier onlyProtocolOperator() {
        if (msg.sender != i_protocolOperator) {
            revert LendingPool__CallerNotAuthorized();
        }
        _;
    }

    ///////////////////
    // External Functions
    ///////////////////

    function depositToken(
        uint256 amount
    ) external moreThanZero(amount) nonReentrant {
        uint256 interestAccrued = _updateLiquidityIndex();
        s_lender[msg.sender].amount = _getUpdatedLenderDeposit() + amount;
        s_totalLiquidity += interestAccrued + amount;
        emit TokenDeposited(msg.sender, amount);
        bool success = IERC20(i_underlyingAssetAddress).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    function withdrawToken(
        uint256 amount
    ) external moreThanZero(amount) liquidityAvailable(amount) nonReentrant {
        uint256 interestAccrued = _updateLiquidityIndex();
        s_lender[msg.sender].amount = _getUpdatedLenderDeposit() - amount;
        s_totalLiquidity += interestAccrued - amount;
        emit TokenWithdrawn(msg.sender, amount);
        bool success = IERC20(i_underlyingAssetAddress).transferFrom(
            address(this),
            msg.sender,
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    function liquidate(
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 interestAccrued = _updateBorrowerIndex();
        BorrowerBalance storage borrower = s_borrower[user];
        borrower.debt = _getUpdatedBorrowerDebt(user);
        uint256 startingHealthFactor = _healthFactor(user, borrower.debt);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert LendingPool__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getUsdValue(debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(totalCollateralToRedeem, user, msg.sender);
        _repayDebt(debtToCover, user, msg.sender);
        s_totalBorrowed += interestAccrued - debtToCover;
        uint256 endingHealthFactor = _healthFactor(user, borrower.debt);
        if (endingHealthFactor <= startingHealthFactor) {
            revert LendingPool__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    function depositCollateralAndBorrowToken(
        uint256 amountCollateral,
        uint256 amountToBorrow
    ) external {
        depositCollateral(amountCollateral);
        borrowToken(amountToBorrow);
    }

    function repayDebtAndRedeemCollateral(
        uint256 amountDebtToRepay,
        uint256 amountCollateralToRedeem
    ) external {
        repayDebt(amountDebtToRepay);
        redeemCollateral(amountCollateralToRedeem);
    }

    function withdrawProtocolReserves(
        address to,
        uint256 amount
    ) external onlyProtocolOperator moreThanZero(amount) nonReentrant {
        s_protocolReserve -= amount;
        bool success = IERC20(i_underlyingAssetAddress).transferFrom(
            address(this),
            to,
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    ///////////////////
    // Public Functions
    ///////////////////

    function getLiquidityAvailable() public view returns (uint256) {
        uint256 availableLiquidity = IERC20(i_underlyingAssetAddress).balanceOf(
            address(this)
        ) - s_protocolReserve;
        return availableLiquidity;
    }

    function depositCollateral(
        uint256 amount
    ) public moreThanZero(amount) nonReentrant {
        s_borrower[msg.sender].collateral += amount;
        emit CollateralDeposited(msg.sender, amount);
        bool success = IERC20(i_collateralAddress).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    function borrowToken(
        uint256 amount
    ) public moreThanZero(amount) liquidityAvailable(amount) nonReentrant {
        uint256 interestAccrued = _updateBorrowerIndex();
        s_borrower[msg.sender].debt =
            _getUpdatedBorrowerDebt(msg.sender) +
            amount;
        s_totalBorrowed += interestAccrued + amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        emit TokenBorrowed(msg.sender, amount);
        bool success = IERC20(i_underlyingAssetAddress).transferFrom(
            address(this),
            msg.sender,
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    function repayDebt(
        uint256 amount
    ) public moreThanZero(amount) nonReentrant {
        uint256 interestAccrued = _updateBorrowerIndex();
        s_totalBorrowed += interestAccrued - amount;
        _repayDebt(amount, msg.sender, msg.sender);
    }

    function redeemCollateral(
        uint256 amount
    ) public moreThanZero(amount) nonReentrant {
        _redeemCollateral(amount, address(this), msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getUsdValue(uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            i_collateralPriceFeedAddress
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function previewCurrentLiquidityIndex()
        public
        view
        returns (InterestIndex memory)
    {
        InterestIndex memory idx = s_liquidityIndex;

        uint256 dt = block.timestamp - idx.lastUpdate;

        (
            uint256 accruedTotalLiquidity,
            uint256 accruedTotalBorrowed
        ) = _previewAccruedTotals();
        uint256 utilization = InterestLib.calculateUtilization(
            accruedTotalLiquidity,
            accruedTotalBorrowed
        );
        uint256 borrowRate = InterestLib.calculateBorrowRate(
            utilization,
            i_baseRate,
            i_slope,
            i_baseRateAtKink,
            i_slopeAtKink
        );
        uint256 lenderRate = InterestLib.calculateLenderInterest(
            borrowRate,
            utilization,
            i_reserveFactor
        );

        if (lenderRate != 0) {
            uint256 factor = InterestLib.calculateIndexUpdate(dt, lenderRate);
            idx.index = (idx.index * factor) / PRECISION;
        }

        idx.lastUpdate = block.timestamp;
        return idx;
    }

    function previewCurrentBorrowerIndex()
        public
        view
        returns (InterestIndex memory)
    {
        InterestIndex memory idx = s_borrowerIndex;

        uint256 dt = block.timestamp - idx.lastUpdate;

        (
            uint256 accruedTotalLiquidity,
            uint256 accruedTotalBorrowed
        ) = _previewAccruedTotals();
        uint256 utilization = InterestLib.calculateUtilization(
            accruedTotalLiquidity,
            accruedTotalBorrowed
        );
        uint256 borrowRate = InterestLib.calculateBorrowRate(
            utilization,
            i_baseRate,
            i_slope,
            i_baseRateAtKink,
            i_slopeAtKink
        );

        if (borrowRate != 0) {
            uint256 factor = InterestLib.calculateIndexUpdate(dt, borrowRate);
            idx.index = (idx.index * factor) / PRECISION;
        }

        idx.lastUpdate = block.timestamp;
        return idx;
    }

    function getBorrowerDebt(address user) public view returns (uint256) {
        BorrowerBalance memory borrowerBalance = s_borrower[user];
        InterestIndex memory idx = previewCurrentBorrowerIndex();
        if (borrowerBalance.index == 0) {
            return 0;
        }

        uint256 updatedBorrowerDebt = ((borrowerBalance.debt * idx.index) /
            borrowerBalance.index);
        return updatedBorrowerDebt;
    }

    ///////////////////
    // Internal Functions
    ///////////////////

    function _redeemCollateral(
        uint256 amount,
        address from,
        address to
    ) private {
        s_borrower[from].collateral -= amount;
        emit CollateralRedeemed(from, to, amount);
        bool success = IERC20(i_collateralAddress).transferFrom(
            from,
            to,
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    function _repayDebt(
        uint256 amount,
        address debtOf,
        address repayer
    ) internal {
        s_borrower[debtOf].debt = _getUpdatedBorrowerDebt(debtOf) - amount;
        bool success = IERC20(i_underlyingAssetAddress).transferFrom(
            repayer,
            address(this),
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    function _getUpdatedBorrowerDebt(address user) internal returns (uint256) {
        BorrowerBalance storage borrowerBalance = s_borrower[user];
        InterestIndex storage borrowerIndex = s_borrowerIndex;

        if (borrowerBalance.index == 0) {
            borrowerBalance.index = borrowerIndex.index;
        }
        uint256 updatedBorrowerDebt = (borrowerBalance.debt *
            borrowerIndex.index) / borrowerBalance.index;
        borrowerBalance.index = borrowerIndex.index;
        return updatedBorrowerDebt;
    }

    function _updateBorrowerIndex() internal returns (uint256 interestAccrued) {
        InterestIndex storage idx = s_borrowerIndex;

        uint256 dt = block.timestamp - idx.lastUpdate;
        if (dt == 0) return 0;

        uint256 borrowRate = _calculateBorrowRate();

        if (borrowRate != 0) {
            interestAccrued = InterestLib.calculateInterestAccrued(
                s_totalBorrowed,
                borrowRate,
                dt
            );
            s_protocolReserve +=
                (interestAccrued * i_reserveFactor) /
                PRECISION;

            uint256 factor = InterestLib.calculateIndexUpdate(dt, borrowRate);

            idx.index = (idx.index * factor) / PRECISION;
        }

        idx.lastUpdate = block.timestamp;
    }

    function _getUpdatedLenderDeposit() internal returns (uint256) {
        LenderBalance storage lenderBalance = s_lender[msg.sender];
        InterestIndex storage liquidityIndex = s_liquidityIndex;

        if (lenderBalance.index == 0) {
            lenderBalance.index = liquidityIndex.index;
        }
        uint256 updatedBalance = (lenderBalance.amount * liquidityIndex.index) /
            lenderBalance.index;
        lenderBalance.index = liquidityIndex.index;
        return updatedBalance;
    }

    function _updateLiquidityIndex()
        internal
        returns (uint256 lenderInterestAccrued)
    {
        InterestIndex storage idx = s_liquidityIndex;

        uint256 dt = block.timestamp - idx.lastUpdate;
        if (dt == 0) return 0;

        uint256 lenderRate = _calculateLenderRate();

        if (lenderRate != 0) {
            lenderInterestAccrued = InterestLib.calculateInterestAccrued(
                s_totalLiquidity,
                lenderRate,
                dt
            );
            uint256 factor = InterestLib.calculateIndexUpdate(dt, lenderRate);
            idx.index = (idx.index * factor) / PRECISION;
        }

        idx.lastUpdate = block.timestamp;
    }

    ///////////////////
    // Internal & Private View & Pure Functions
    ///////////////////

    function _previewAccruedTotals()
        private
        view
        returns (uint256 totalLiquidity, uint256 totalBorrowed)
    {
        totalBorrowed = s_totalBorrowed;
        totalLiquidity = s_totalLiquidity;

        uint256 borrowDt = block.timestamp - s_borrowerIndex.lastUpdate;
        if (borrowDt > 0 && totalBorrowed > 0) {
            uint256 borrowRate = _calculateBorrowRate();
            if (borrowRate > 0) {
                uint256 interestAccrued = InterestLib.calculateInterestAccrued(
                    totalBorrowed,
                    borrowRate,
                    borrowDt
                );
                totalBorrowed += interestAccrued;
            }
        }

        uint256 lenderDt = block.timestamp - s_liquidityIndex.lastUpdate;
        if (lenderDt > 0 && totalLiquidity > 0) {
            uint256 lenderRate = _calculateLenderRate();
            if (lenderRate > 0) {
                uint256 lenderInterest = InterestLib.calculateInterestAccrued(
                    totalLiquidity,
                    lenderRate,
                    lenderDt
                );
                totalLiquidity += lenderInterest;
            }
        }
    }

    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user, s_borrower[user].debt);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert LendingPool__HealthFactorBroken(userHealthFactor);
        }
    }

    function _calculateBorrowRate() private view returns (uint256) {
        uint256 utilization = InterestLib.calculateUtilization(
            s_totalLiquidity,
            s_totalBorrowed
        );
        return
            InterestLib.calculateBorrowRate(
                utilization,
                i_baseRate,
                i_slope,
                i_baseRateAtKink,
                i_slopeAtKink
            );
    }

    function _calculateLenderRate() private view returns (uint256) {
        uint256 utilization = InterestLib.calculateUtilization(
            s_totalLiquidity,
            s_totalBorrowed
        );
        uint256 borrowRate = _calculateBorrowRate();
        return
            InterestLib.calculateLenderInterest(
                borrowRate,
                utilization,
                i_reserveFactor
            );
    }

    function _healthFactor(
        address user,
        uint256 debt
    ) private view returns (uint256) {
        BorrowerBalance storage borrower = s_borrower[user];
        uint256 collateralValueInUsd = getUsdValue(borrower.collateral);
        if (debt == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / debt;
    }

    ///////////////////
    // External & Public View & Pure Functions
    ///////////////////

    function getHealthFactor(address user) external view returns (uint256) {
        uint256 borrowerDebt = getBorrowerDebt(user);
        return _healthFactor(user, borrowerDebt);
    }

    function getUnderlyingAssetAddress() external view returns (address) {
        return i_underlyingAssetAddress;
    }

    function getTotalLiquidity() external view returns (uint256) {
        (uint256 totalLiquidity, ) = _previewAccruedTotals();
        return totalLiquidity;
    }

    function getTotalBorrowed() external view returns (uint256) {
        (, uint256 totalBorrowed) = _previewAccruedTotals();
        return totalBorrowed;
    }

    function getCollateralAddress() external view returns (address) {
        return i_collateralAddress;
    }

    function getDepositAmount(address user) external view returns (uint256) {
        LenderBalance memory lenderBalance = s_lender[user];
        InterestIndex memory idx = previewCurrentLiquidityIndex();

        if (lenderBalance.index == 0) {
            return 0;
        }
        uint256 updatedBalance = ((lenderBalance.amount * idx.index) /
            lenderBalance.index);
        return updatedBalance;
    }

    function getLiquidityIndex() external view returns (InterestIndex memory) {
        return s_liquidityIndex;
    }

    function getBorrowIndex() external view returns (InterestIndex memory) {
        return s_borrowerIndex;
    }

    function getCollateralValue(address user) external view returns (uint256) {
        return getUsdValue(s_borrower[user].collateral);
    }

    function getLenderInterestRate() external view returns (uint256) {
        return _calculateLenderRate();
    }
}
