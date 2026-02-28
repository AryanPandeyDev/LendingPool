// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {InterestLib} from "./libraries/InterestLib.sol";
import {
    AggregatorV3Interface
} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/// @title LendingPool
/// @author AryanPandeyDev
/// @notice A single-asset lending pool that accepts ERC-20 deposits, allows overcollateralised
///         borrowing against a separate ERC-20 collateral, and accrues interest via a
///         ray-indexed model inspired by Aave V2.
/// @dev Interest is tracked through two cumulative indexes (liquidity & borrower) that grow
///      over time. Individual balances are rebased against these indexes on every interaction.
///      A kinked interest-rate curve governs borrow / lender rates, and a configurable reserve
///      factor skims protocol revenue from borrower interest.
contract LendingPool is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////

    /// @dev Thrown when a user attempts an action with a zero amount.
    error LendingPool__AmountMustBeMoreThanZero();
    /// @dev Thrown when an ERC-20 transfer or transferFrom call returns false.
    error LendingPool__TransferFailed();
    /// @dev Thrown when a withdrawal or borrow exceeds the pool's available liquidity.
    error LendingPool__NotEnoughLiquidityAvailable();
    /// @dev Thrown when a borrower's health factor falls below MIN_HEALTH_FACTOR after an action.
    error LendingPool__HealthFactorBroken(uint256 healthFactor);
    /// @dev Thrown when a liquidation is attempted on a borrower whose health factor is still safe.
    error LendingPool__HealthFactorOk();
    /// @dev Thrown when a liquidation does not improve the borrower's health factor.
    error LendingPool__HealthFactorNotImproved();
    /// @dev Thrown when a restricted function is called by someone other than the protocol operator.
    error LendingPool__CallerNotAuthorized();

    ///////////////////
    // Types
    ///////////////////

    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////

    /// @dev Per-lender normalised deposit balance and personal index snapshot.
    mapping(address lender => LenderBalance) private s_lender;
    /// @dev Global cumulative liquidity (lender) index and its last-update timestamp.
    InterestIndex private s_liquidityIndex;
    /// @dev Per-borrower normalised debt, collateral amount, and personal index snapshot.
    mapping(address borrower => BorrowerBalance) private s_borrower;
    /// @dev Global cumulative borrower index and its last-update timestamp.
    InterestIndex private s_borrowerIndex;
    /// @dev Aggregate deposited liquidity (accrued via lender interest).
    uint256 private s_totalLiquidity;
    /// @dev Aggregate outstanding borrows (accrued via borrower interest).
    uint256 private s_totalBorrowed;
    /// @dev Accumulated protocol revenue from the reserve factor cut of borrower interest.
    uint256 private s_protocolReserve;

    /// @dev Base interest rate applied below the kink (annualised, 1e18 = 100 %).
    uint256 private immutable i_baseRate;
    /// @dev Slope of the interest-rate curve below the kink.
    uint256 private immutable i_slope;
    /// @dev Base interest rate applied at and above the kink.
    uint256 private immutable i_baseRateAtKink;
    /// @dev Slope of the interest-rate curve above the kink.
    uint256 private immutable i_slopeAtKink;
    /// @dev Fraction of borrower interest retained by the protocol (1e18 = 100 %).
    uint256 private immutable i_reserveFactor;
    /// @dev Chainlink price feed for the collateral asset (denominated in USD).
    address private immutable i_collateralPriceFeedAddress;
    /// @dev ERC-20 token that lenders deposit and borrowers receive.
    address private immutable i_underlyingAssetAddress;
    /// @dev ERC-20 token used as collateral by borrowers.
    address private immutable i_collateralAddress;
    /// @dev Address authorised to withdraw protocol reserves.
    address private immutable i_protocolOperator;

    /// @dev Fixed-point precision constant (1e18).
    uint256 private constant PRECISION = 1e18;
    /// @dev Scale factor to normalise 8-decimal Chainlink prices to 18 decimals.
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    /// @dev Minimum acceptable health factor (1e18 means 1:1 collateral cover after threshold).
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    /// @dev Seed value for both interest indexes at deployment.
    uint256 private constant STARTING_LIQUIDITY_INDEX = 1e18;
    /// @dev Percentage of collateral value considered when computing health factor (75 %).
    uint256 private constant LIQUIDATION_THRESHOLD = 75;
    /// @dev Denominator paired with LIQUIDATION_THRESHOLD and LIQUIDATION_BONUS.
    uint256 private constant LIQUIDATION_PRECISION = 100;
    /// @dev Extra percentage of collateral awarded to liquidators as incentive (5 %).
    uint256 private constant LIQUIDATION_BONUS = 5;

    ///////////////////
    // Events
    ///////////////////

    /// @notice Emitted when a lender deposits the underlying asset into the pool.
    /// @param user The depositor's address.
    /// @param amount The amount of underlying tokens deposited.
    event TokenDeposited(address indexed user, uint256 amount);

    /// @notice Emitted when a borrower deposits collateral into the pool.
    /// @param user The depositor's address.
    /// @param amount The amount of collateral tokens deposited.
    event CollateralDeposited(address indexed user, uint256 amount);

    /// @notice Emitted when a borrower takes a loan from the pool.
    /// @param user The borrower's address.
    /// @param amount The amount of underlying tokens borrowed.
    event TokenBorrowed(address indexed user, uint256 amount);

    /// @notice Emitted when a lender withdraws underlying tokens from the pool.
    /// @param user The withdrawer's address.
    /// @param amount The amount of underlying tokens withdrawn.
    event TokenWithdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a borrower repays part or all of their outstanding debt.
    /// @param user The repayer's address.
    /// @param amount The amount of underlying tokens repaid.
    event DebtRepaid(address indexed user, uint256 amount);

    /// @notice Emitted when a liquidator repays another borrower's debt in exchange for collateral.
    /// @param liquidator The address performing the liquidation.
    /// @param borrower The address of the underwater borrower.
    /// @param debtCovered The amount of debt repaid by the liquidator.
    /// @param collateralSeized The total collateral (including bonus) transferred to the liquidator.
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtCovered,
        uint256 collateralSeized
    );

    /// @notice Emitted when collateral is transferred from a borrower to another address.
    /// @param from The borrower whose collateral is redeemed.
    /// @param to The recipient of the collateral.
    /// @param amount The amount of collateral tokens transferred.
    event CollateralRedeemed(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    ///////////////////
    // Structs
    ///////////////////

    /// @notice Tracks a lender's normalised deposit and the liquidity index at which it was last updated.
    /// @param amount The lender's deposit balance (normalised against `s_liquidityIndex`).
    /// @param index The value of `s_liquidityIndex.index` at the time of the last user interaction.
    struct LenderBalance {
        uint256 amount;
        uint256 index;
    }

    /// @notice Tracks a borrower's normalised debt, raw collateral, and the borrow index snapshot.
    /// @param debt The borrower's debt balance (normalised against `s_borrowerIndex`).
    /// @param collateral The raw amount of collateral tokens held by this borrower.
    /// @param index The value of `s_borrowerIndex.index` at the time of the last user interaction.
    struct BorrowerBalance {
        uint256 debt;
        uint256 collateral;
        uint256 index;
    }

    /// @notice Stores a cumulative interest index together with its last-update timestamp.
    /// @param index The cumulative interest multiplier (starts at 1e18).
    /// @param lastUpdate The `block.timestamp` of the most recent update.
    struct InterestIndex {
        uint256 index;
        uint256 lastUpdate;
    }

    ///////////////////
    // Constructor
    ///////////////////

    /// @notice Deploys a new LendingPool for the given asset pair and interest-rate parameters.
    /// @param _underlyingAssetAddress ERC-20 token that lenders deposit / borrowers receive.
    /// @param _collateralAddress ERC-20 token used as borrower collateral.
    /// @param _baseRate Annualised base interest rate below the kink (1e18 = 100 %).
    /// @param _slope Interest-rate slope below the kink.
    /// @param baseRateAtKink Annualised base rate at and above the kink.
    /// @param slopeAtKink Interest-rate slope above the kink.
    /// @param reserveFactor Fraction of borrower interest kept as protocol revenue (1e18 = 100 %).
    /// @param _collateralPriceFeedAddress Chainlink ETH/USD (or equivalent) price feed for the collateral.
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

    /// @dev Reject any ETH sent directly to this contract.
    receive() external payable {
        revert();
    }

    ///////////////////
    // Modifiers
    ///////////////////

    /// @dev Reverts if `amount` is zero.
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingPool__AmountMustBeMoreThanZero();
        }
        _;
    }

    /// @dev Reverts if `amount` exceeds the pool's available (non-reserved) liquidity.
    modifier liquidityAvailable(uint256 amount) {
        if (amount > getLiquidityAvailable()) {
            revert LendingPool__NotEnoughLiquidityAvailable();
        }
        _;
    }

    /// @dev Restricts access to the protocol operator set at deployment.
    modifier onlyProtocolOperator() {
        if (msg.sender != i_protocolOperator) {
            revert LendingPool__CallerNotAuthorized();
        }
        _;
    }

    ///////////////////
    // External Functions
    ///////////////////

    /// @notice Deposits underlying tokens into the pool to earn interest.
    /// @dev Accrues lender interest before updating the caller's balance and `s_totalLiquidity`.
    ///      Transfers tokens from the caller via `transferFrom` — caller must have approved this contract.
    /// @param amount The amount of underlying tokens to deposit (must be > 0).
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

    /// @notice Withdraws underlying tokens from the pool.
    /// @dev Accrues lender interest, checks that the pool has enough idle liquidity, then
    ///      decreases the caller's balance and transfers tokens out.
    /// @param amount The amount of underlying tokens to withdraw (must be > 0 and ≤ available liquidity).
    function withdrawToken(
        uint256 amount
    ) external moreThanZero(amount) liquidityAvailable(amount) nonReentrant {
        uint256 interestAccrued = _updateLiquidityIndex();
        s_lender[msg.sender].amount = _getUpdatedLenderDeposit() - amount;
        s_totalLiquidity = (s_totalLiquidity + interestAccrued) - amount;
        emit TokenWithdrawn(msg.sender, amount);
        bool success = IERC20(i_underlyingAssetAddress).transfer(
            msg.sender,
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    /// @notice Liquidates an underwater borrower by repaying part of their debt in exchange for
    ///         their collateral plus a liquidation bonus.
    /// @dev Workflow:
    ///      1. Accrue borrower interest and rebase the target user's debt.
    ///      2. Verify the borrower's health factor is below MIN_HEALTH_FACTOR.
    ///      3. Compute the collateral to seize (debt value + 5 % bonus).
    ///      4. Transfer collateral to the liquidator, pull repayment tokens from the liquidator.
    ///      5. Verify that the borrower's health factor has improved.
    /// @param user The address of the borrower being liquidated.
    /// @param debtToCover The amount of debt (in underlying tokens) the liquidator wishes to cover.
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
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(totalCollateralToRedeem, user, msg.sender);
        s_borrower[user].debt -= debtToCover;
        _repayDebt(debtToCover, msg.sender);
        s_totalBorrowed = (s_totalBorrowed + interestAccrued) - debtToCover;
        uint256 endingHealthFactor = _healthFactor(user, borrower.debt);
        if (endingHealthFactor <= startingHealthFactor) {
            revert LendingPool__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
        emit Liquidated(msg.sender, user, debtToCover, totalCollateralToRedeem);
    }

    /// @notice Convenience function that deposits collateral and borrows in a single transaction.
    /// @param amountCollateral The amount of collateral tokens to deposit.
    /// @param amountToBorrow The amount of underlying tokens to borrow.
    function depositCollateralAndBorrowToken(
        uint256 amountCollateral,
        uint256 amountToBorrow
    ) external {
        depositCollateral(amountCollateral);
        borrowToken(amountToBorrow);
    }

    /// @notice Convenience function that repays debt and redeems collateral in a single transaction.
    /// @param amountDebtToRepay The amount of debt to repay.
    /// @param amountCollateralToRedeem The amount of collateral to withdraw.
    function repayDebtAndRedeemCollateral(
        uint256 amountDebtToRepay,
        uint256 amountCollateralToRedeem
    ) external {
        repayDebt(amountDebtToRepay);
        redeemCollateral(amountCollateralToRedeem);
    }

    /// @notice Allows the protocol operator to withdraw accumulated reserve revenue.
    /// @dev Only callable by `i_protocolOperator`. Decrements `s_protocolReserve` and transfers tokens.
    /// @param to The recipient address.
    /// @param amount The amount of underlying tokens to withdraw from reserves.
    function withdrawProtocolReserves(
        address to,
        uint256 amount
    ) external onlyProtocolOperator moreThanZero(amount) nonReentrant {
        s_protocolReserve -= amount;
        bool success = IERC20(i_underlyingAssetAddress).transfer(to, amount);
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    ///////////////////
    // Public Functions
    ///////////////////

    /// @notice Converts a USD-denominated value to the equivalent amount of collateral tokens.
    /// @dev Uses the Chainlink price feed and applies `ADDITIONAL_FEED_PRECISION` scaling.
    /// @param usdAmount The value in USD (18-decimal fixed-point).
    /// @return The equivalent collateral token amount (18-decimal).
    function getTokenAmountFromUsd(
        uint256 usdAmount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            i_collateralPriceFeedAddress
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            (usdAmount * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /// @notice Returns the pool's available (non-reserved) liquidity that can be borrowed or withdrawn.
    /// @return The amount of underlying tokens available.
    function getLiquidityAvailable() public view returns (uint256) {
        uint256 availableLiquidity = IERC20(i_underlyingAssetAddress).balanceOf(
            address(this)
        ) - s_protocolReserve;
        return availableLiquidity;
    }

    /// @notice Deposits collateral tokens that back the caller's borrow positions.
    /// @dev Transfers tokens from the caller via `transferFrom` — caller must have approved this contract.
    /// @param amount The amount of collateral tokens to deposit (must be > 0).
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

    /// @notice Borrows underlying tokens against the caller's deposited collateral.
    /// @dev Accrues borrower interest, increases the caller's debt, checks health factor, then transfers.
    /// @param amount The amount of underlying tokens to borrow (must be > 0 and ≤ available liquidity).
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
        bool success = IERC20(i_underlyingAssetAddress).transfer(
            msg.sender,
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    /// @notice Repays part or all of the caller's outstanding debt.
    /// @dev Accrues borrower interest, updates `s_totalBorrowed`, rebases the caller's debt, and transfers
    ///      tokens from the caller back into the pool.
    /// @param amount The amount of underlying tokens to repay (must be > 0).
    function repayDebt(
        uint256 amount
    ) public moreThanZero(amount) nonReentrant {
        uint256 interestAccrued = _updateBorrowerIndex();
        s_totalBorrowed = (s_totalBorrowed + interestAccrued) - amount;
        s_borrower[msg.sender].debt =
            _getUpdatedBorrowerDebt(msg.sender) -
            amount;
        _repayDebt(amount, msg.sender);
        emit DebtRepaid(msg.sender, amount);
    }

    /// @notice Withdraws collateral tokens from the caller's borrower position.
    /// @dev Reverts if the withdrawal would cause the caller's health factor to drop below 1.
    /// @param amount The amount of collateral tokens to redeem (must be > 0).
    function redeemCollateral(
        uint256 amount
    ) public moreThanZero(amount) nonReentrant {
        _redeemCollateral(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /// @notice Converts a raw collateral-token amount to its USD value.
    /// @dev Uses the Chainlink price feed and applies `ADDITIONAL_FEED_PRECISION` scaling.
    /// @param amount The amount of collateral tokens.
    /// @return The equivalent USD value (18-decimal fixed-point).
    function getUsdValue(uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            i_collateralPriceFeedAddress
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /// @notice Simulates what the liquidity index would be if it were updated right now.
    /// @dev Uses `_previewAccruedTotals` for utilisation and rate calculations without modifying state.
    /// @return An `InterestIndex` struct with the projected index value and `block.timestamp`.
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

    /// @notice Simulates what the borrower index would be if it were updated right now.
    /// @dev Uses `_previewAccruedTotals` for utilisation and rate calculations without modifying state.
    /// @return An `InterestIndex` struct with the projected index value and `block.timestamp`.
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

    /// @notice Returns the current (accrued) debt of a borrower, including unpaid interest.
    /// @dev Uses `previewCurrentBorrowerIndex` so the result is accurate even between state-changing calls.
    /// @param user The borrower's address.
    /// @return The borrower's total outstanding debt in underlying-token units.
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

    /// @dev Transfers collateral tokens from borrower `from` to address `to`.
    ///      Decrements the borrower's tracked collateral and emits {CollateralRedeemed}.
    /// @param amount The amount of collateral tokens to redeem.
    /// @param from The borrower whose collateral is being seized.
    /// @param to The recipient (the borrower themselves or a liquidator).
    function _redeemCollateral(
        uint256 amount,
        address from,
        address to
    ) private {
        s_borrower[from].collateral -= amount;
        emit CollateralRedeemed(from, to, amount);
        bool success = IERC20(i_collateralAddress).transfer(to, amount);
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    /// @dev Pulls underlying tokens from `repayer` into the pool.
    ///      Callers are responsible for updating the borrower's debt accounting before calling this.
    /// @param amount The amount of underlying tokens to transfer in.
    /// @param repayer The address providing the repayment tokens.
    function _repayDebt(uint256 amount, address repayer) internal {
        bool success = IERC20(i_underlyingAssetAddress).transferFrom(
            repayer,
            address(this),
            amount
        );
        if (!success) {
            revert LendingPool__TransferFailed();
        }
    }

    /// @dev Rebases a borrower's debt against the current `s_borrowerIndex`, snapshotting their
    ///      personal index. On first interaction the borrower's index is initialised.
    /// @param user The borrower's address.
    /// @return updatedBorrowerDebt The borrower's debt after applying accrued interest.
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

    /// @dev Accrues global borrower interest: computes interest since last update, grows the
    ///      borrow index, and adds the reserve factor share to `s_protocolReserve`.
    /// @return interestAccrued The total interest accrued on `s_totalBorrowed` during this period.
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

    /// @dev Rebases a lender's deposit against the current `s_liquidityIndex`, snapshotting
    ///      their personal index. On first interaction the lender's index is initialised.
    /// @return The lender's deposit balance after applying accrued interest.
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

    /// @dev Accrues global lender interest: computes interest since last update and grows the
    ///      liquidity index.
    /// @return lenderInterestAccrued The total interest accrued on `s_totalLiquidity` during this period.
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

    /// @dev Simulates the effect of accruing interest on both totals without writing to storage.
    ///      Used by view functions to return up-to-date values.
    /// @return totalLiquidity The total deposited liquidity after simulated accrual.
    /// @return totalBorrowed The total outstanding borrows after simulated accrual.
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

    /// @dev Reverts with {LendingPool__HealthFactorBroken} if `user`'s health factor is below 1.
    /// @param user The borrower address to check.
    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user, s_borrower[user].debt);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert LendingPool__HealthFactorBroken(userHealthFactor);
        }
    }

    /// @dev Returns the current annualised borrow rate based on pool utilisation.
    /// @return The borrow rate (1e18 = 100 % per year).
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

    /// @dev Returns the current annualised lender rate, derived from the borrow rate, utilisation,
    ///      and reserve factor.
    /// @return The lender rate (1e18 = 100 % per year).
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

    /// @dev Computes a borrower's health factor as:
    ///      `(collateralUSD * LIQUIDATION_THRESHOLD / 100) * 1e18 / debt`
    ///      Returns `type(uint256).max` when `debt == 0` (infinitely healthy).
    /// @param user The borrower address.
    /// @param debt The borrower's current (possibly rebased) debt.
    /// @return The health factor (1e18 = exactly at liquidation threshold).
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

    /// @notice Returns the liquidation threshold percentage (75).
    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    /// @notice Returns the accumulated protocol reserve (not yet withdrawn).
    function getProtocolReserve() external view returns (uint256) {
        return s_protocolReserve;
    }

    /// @notice Returns a borrower's current health factor, including accrued interest.
    /// @param user The borrower's address.
    /// @return The health factor (1e18 = at threshold; > 1e18 = safe; < 1e18 = liquidatable).
    function getHealthFactor(address user) external view returns (uint256) {
        uint256 borrowerDebt = getBorrowerDebt(user);
        return _healthFactor(user, borrowerDebt);
    }

    /// @notice Returns the address of the underlying (deposit / borrow) ERC-20 token.
    function getUnderlyingAssetAddress() external view returns (address) {
        return i_underlyingAssetAddress;
    }

    /// @notice Returns the total deposited liquidity including accrued lender interest.
    function getTotalLiquidity() external view returns (uint256) {
        (uint256 totalLiquidity, ) = _previewAccruedTotals();
        return totalLiquidity;
    }

    /// @notice Returns the total outstanding borrows including accrued borrower interest.
    function getTotalBorrowed() external view returns (uint256) {
        (, uint256 totalBorrowed) = _previewAccruedTotals();
        return totalBorrowed;
    }

    /// @notice Returns the address of the collateral ERC-20 token.
    function getCollateralAddress() external view returns (address) {
        return i_collateralAddress;
    }

    /// @notice Returns a lender's current deposit balance including accrued interest.
    /// @param user The lender's address.
    /// @return The up-to-date deposit balance.
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

    /// @notice Returns the raw (stored) liquidity index struct.
    function getLiquidityIndex() external view returns (InterestIndex memory) {
        return s_liquidityIndex;
    }

    /// @notice Returns the raw (stored) borrower index struct.
    function getBorrowIndex() external view returns (InterestIndex memory) {
        return s_borrowerIndex;
    }

    /// @notice Returns the USD value of a borrower's deposited collateral.
    /// @param user The borrower's address.
    function getCollateralValue(address user) external view returns (uint256) {
        return getUsdValue(s_borrower[user].collateral);
    }

    /// @notice Returns the current annualised lender interest rate.
    function getLenderInterestRate() external view returns (uint256) {
        return _calculateLenderRate();
    }

    /// @notice Returns the current annualised borrower interest rate.
    function getBorrowerInterestRate() external view returns (uint256) {
        return _calculateBorrowRate();
    }

    /// @notice Returns the address of the protocol operator set at deployment.
    function getProtocolOperator() external view returns (address) {
        return i_protocolOperator;
    }
}
