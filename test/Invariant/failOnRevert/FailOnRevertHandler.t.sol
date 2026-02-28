// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../../src/LendingPool.sol";
import {FakeERC20} from "../../mocks/FakeERC20.sol";

/// @title FailOnRevertHandler
/// @notice Handler contract for the fail-on-revert invariant test suite.
/// @dev Every function carefully bounds its inputs so that the underlying LendingPool call
///      will NOT revert. This ensures that the fuzzer exercises real state transitions on
///      every call, giving maximum confidence that invariants hold under valid usage.
///
///      Key design decisions:
///      - Actors are created lazily via `_getActor`. Roughly 1-in-4 calls (ACTOR_DISCRIMINATOR)
///        create a new actor; the rest reuse an existing one. This balances multi-user coverage
///        with per-user depth.
///      - Ghost variables (`ghost_previousLiquidityIndex`, `ghost_previousBorrowerIndex`) are
///        snapshotted after every state-changing call so the invariant file can verify index
///        monotonicity.
contract FailOnRevertHandler is Test {
    LendingPool public immutable lendingPool;
    FakeERC20 public immutable usdc;
    FakeERC20 public immutable weth;
    address public immutable protocolOperator;

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 75;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 5;
    /// @dev Upper bound on token amounts to prevent overflow in interest calculations.
    uint256 private constant MAX_TOKEN_AMOUNT = 1_000_000_000e18;
    /// @dev Controls actor creation frequency: new actor when `actorSeed % ACTOR_DISCRIMINATOR == 0`.
    uint256 private constant ACTOR_DISCRIMINATOR = 4;

    /// @dev Dynamic array of all actors that have interacted with the pool.
    address[] private s_actors;
    /// @dev Prevents duplicate actor entries.
    mapping(address actor => bool isKnown) private s_isKnownActor;

    // ── Ghost variables for index monotonicity invariant ─────────────────
    uint256 public ghost_previousLiquidityIndex;
    uint256 public ghost_previousBorrowerIndex;

    constructor(LendingPool _lendingPool, address _protocolOperator) {
        lendingPool = _lendingPool;
        protocolOperator = _protocolOperator;
        usdc = FakeERC20(lendingPool.getUnderlyingAssetAddress());
        weth = FakeERC20(lendingPool.getCollateralAddress());

        // Snapshot the starting index values
        ghost_previousLiquidityIndex = lendingPool.getLiquidityIndex().index;
        ghost_previousBorrowerIndex = lendingPool.getBorrowIndex().index;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Handler actions — each one maps 1:1 to a LendingPool entry point
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deposits underlying tokens (USDC) into the pool as a lender.
    function depositToken(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1, MAX_TOKEN_AMOUNT);

        _mintAndApproveUsdc(actor, amount);

        vm.prank(actor);
        lendingPool.depositToken(amount);
        _updateGhostIndexes();
    }

    /// @notice Withdraws underlying tokens from the pool.
    /// @dev Bounded by `min(userDeposit, availableLiquidity)` to guarantee no revert.
    function withdrawToken(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 userDeposit = lendingPool.getDepositAmount(actor);
        uint256 availableLiquidity = lendingPool.getLiquidityAvailable();
        uint256 maxWithdraw = _min(userDeposit, availableLiquidity);
        if (maxWithdraw == 0) return;

        amount = bound(amount, 1, maxWithdraw);

        vm.prank(actor);
        lendingPool.withdrawToken(amount);
        _updateGhostIndexes();
    }

    /// @notice Attempts to liquidate an underwater borrower.
    /// @dev Finds a borrower with health factor < 1, computes a safe `debtToCover` range,
    ///      and performs the liquidation. Skips if no underwater position exists.
    function liquidate(
        uint256 liquidatorSeed,
        uint256 borrowerSeed,
        uint256 debtToCover
    ) external {
        if (s_actors.length == 0) return;

        address liquidator = _getActor(liquidatorSeed);
        uint256 borrowerIndex = borrowerSeed % s_actors.length;
        address borrower = s_actors[borrowerIndex];
        // Ensure liquidator ≠ borrower when possible
        if (borrower == liquidator && s_actors.length > 1) {
            borrower = s_actors[(borrowerIndex + 1) % s_actors.length];
        }

        // Only liquidate underwater positions
        uint256 healthFactor = lendingPool.getHealthFactor(borrower);
        if (healthFactor >= MIN_HEALTH_FACTOR) return;

        uint256 borrowerDebt = lendingPool.getBorrowerDebt(borrower);
        if (borrowerDebt == 0) return;

        // Compute max debt coverable without exceeding the borrower's collateral
        uint256 collateralUsd = lendingPool.getCollateralValue(borrower);
        if (collateralUsd == 0) return;

        uint256 collateralAmount = lendingPool.getTokenAmountFromUsd(
            collateralUsd
        );
        if (collateralAmount == 0) return;

        uint256 maxCollateralAgainstDebt = (collateralAmount *
            LIQUIDATION_PRECISION) /
            (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);
        if (maxCollateralAgainstDebt == 0) return;

        uint256 maxDebtByCollateral = lendingPool.getUsdValue(
            maxCollateralAgainstDebt
        );
        uint256 maxCover = _min(borrowerDebt, maxDebtByCollateral);
        if (maxCover == 0) return;

        // Cover between 10 % and 100 % of the maxCover
        uint256 minCover = maxCover > 10 ? maxCover / 10 : 1;
        debtToCover = bound(debtToCover, minCover, maxCover);

        _mintAndApproveUsdc(liquidator, debtToCover);

        vm.prank(liquidator);
        lendingPool.liquidate(borrower, debtToCover);
        _updateGhostIndexes();
    }

    /// @notice Deposits collateral and borrows in one call.
    /// @dev Bounds `amountToBorrow` to stay within health-factor and liquidity limits.
    function depositCollateralAndBorrowToken(
        uint256 actorSeed,
        uint256 amountCollateral,
        uint256 amountToBorrow
    ) external {
        address actor = _getActor(actorSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_TOKEN_AMOUNT);

        // Calculate the max additional debt this actor can take on
        uint256 currentDebt = lendingPool.getBorrowerDebt(actor);
        uint256 currentCollateralUsd = lendingPool.getCollateralValue(actor);
        uint256 addedCollateralUsd = lendingPool.getUsdValue(amountCollateral);
        uint256 totalCollateralUsd = currentCollateralUsd + addedCollateralUsd;

        uint256 maxDebtAllowed = (totalCollateralUsd * LIQUIDATION_THRESHOLD) /
            LIQUIDATION_PRECISION;
        if (maxDebtAllowed <= currentDebt) return;

        uint256 availableLiquidity = lendingPool.getLiquidityAvailable();
        uint256 maxBorrow = _min(
            availableLiquidity,
            maxDebtAllowed - currentDebt
        );
        if (maxBorrow == 0) return;

        amountToBorrow = bound(amountToBorrow, 1, maxBorrow);

        _mintAndApproveWeth(actor, amountCollateral);

        vm.prank(actor);
        lendingPool.depositCollateralAndBorrowToken(
            amountCollateral,
            amountToBorrow
        );
        _updateGhostIndexes();
    }

    /// @notice Repays debt and redeems collateral in one call.
    /// @dev Bounds collateral redemption to keep health factor ≥ 1 after the repayment.
    function repayDebtAndRedeemCollateral(
        uint256 actorSeed,
        uint256 amountDebtToRepay,
        uint256 amountCollateralToRedeem
    ) external {
        address actor = _getActor(actorSeed);

        uint256 debt = lendingPool.getBorrowerDebt(actor);
        if (debt == 0) return;
        amountDebtToRepay = bound(amountDebtToRepay, 1, debt);

        uint256 collateralUsd = lendingPool.getCollateralValue(actor);
        uint256 collateralAmount = lendingPool.getTokenAmountFromUsd(
            collateralUsd
        );
        if (collateralAmount == 0) return;

        uint256 debtAfterRepay = debt - amountDebtToRepay;
        uint256 maxRedeem = _maxRedeemableCollateral(
            collateralUsd,
            collateralAmount,
            debtAfterRepay
        );
        if (maxRedeem == 0) return;

        amountCollateralToRedeem = bound(
            amountCollateralToRedeem,
            1,
            maxRedeem
        );

        _mintAndApproveUsdc(actor, amountDebtToRepay);

        vm.prank(actor);
        lendingPool.repayDebtAndRedeemCollateral(
            amountDebtToRepay,
            amountCollateralToRedeem
        );
        _updateGhostIndexes();
    }

    /// @notice Withdraws accumulated protocol reserves.
    function withdrawProtocolReserves(uint256 toSeed, uint256 amount) external {
        uint256 reserve = lendingPool.getProtocolReserve();
        if (reserve == 0) return;

        amount = bound(amount, 1, reserve);
        address to = _getActor(toSeed);

        vm.prank(protocolOperator);
        lendingPool.withdrawProtocolReserves(to, amount);
        _updateGhostIndexes();
    }

    /// @notice Deposits collateral without borrowing.
    function depositCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1, MAX_TOKEN_AMOUNT);

        _mintAndApproveWeth(actor, amount);

        vm.prank(actor);
        lendingPool.depositCollateral(amount);
        _updateGhostIndexes();
    }

    /// @notice Borrows underlying tokens against existing collateral.
    /// @dev Bounded by both available liquidity and the actor's health-factor headroom.
    function borrowToken(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 availableLiquidity = lendingPool.getLiquidityAvailable();
        if (availableLiquidity == 0) return;

        uint256 maxBorrowByHealth = _maxBorrowableByHealth(actor);
        uint256 maxBorrow = _min(availableLiquidity, maxBorrowByHealth);
        if (maxBorrow == 0) return;

        amount = bound(amount, 1, maxBorrow);

        vm.prank(actor);
        lendingPool.borrowToken(amount);
        _updateGhostIndexes();
    }

    /// @notice Repays outstanding debt.
    function repayDebt(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 debt = lendingPool.getBorrowerDebt(actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);

        _mintAndApproveUsdc(actor, amount);

        vm.prank(actor);
        lendingPool.repayDebt(amount);
        _updateGhostIndexes();
    }

    /// @notice Redeems collateral without repaying debt.
    /// @dev Bounded to keep health factor ≥ 1.
    function redeemCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 collateralUsd = lendingPool.getCollateralValue(actor);
        if (collateralUsd == 0) return;

        uint256 collateralAmount = lendingPool.getTokenAmountFromUsd(
            collateralUsd
        );
        if (collateralAmount == 0) return;

        uint256 debt = lendingPool.getBorrowerDebt(actor);
        uint256 maxRedeem = _maxRedeemableCollateral(
            collateralUsd,
            collateralAmount,
            debt
        );
        if (maxRedeem == 0) return;

        amount = bound(amount, 1, maxRedeem);

        vm.prank(actor);
        lendingPool.redeemCollateral(amount);
        _updateGhostIndexes();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  View helpers for the invariant file
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the number of distinct actors that have interacted with the handler.
    function getActorsLength() external view returns (uint256) {
        return s_actors.length;
    }

    /// @notice Returns an actor address selected by `index % s_actors.length`.
    function getActorAt(uint256 index) external view returns (address) {
        if (s_actors.length == 0) return address(0);
        return s_actors[index % s_actors.length];
    }

    /// @notice Returns the full array of known actors (used by the health-factor invariant).
    function getActors() external view returns (address[] memory) {
        return s_actors;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Snapshots both interest indexes after every state-changing handler call.
    function _updateGhostIndexes() internal {
        ghost_previousLiquidityIndex = lendingPool.getLiquidityIndex().index;
        ghost_previousBorrowerIndex = lendingPool.getBorrowIndex().index;
    }

    /// @dev Computes the maximum collateral a borrower can redeem without breaking health factor.
    function _maxRedeemableCollateral(
        uint256 collateralUsd,
        uint256 collateralAmount,
        uint256 debt
    ) internal view returns (uint256) {
        if (debt == 0) {
            return collateralAmount;
        }

        // Minimum collateral USD needed to keep health factor ≥ 1
        uint256 minCollateralUsdRequired = _ceilDiv(
            debt * LIQUIDATION_PRECISION,
            LIQUIDATION_THRESHOLD
        );

        if (collateralUsd <= minCollateralUsdRequired) {
            return 0;
        }

        uint256 redeemableUsd = collateralUsd - minCollateralUsdRequired;
        uint256 redeemableCollateral = lendingPool.getTokenAmountFromUsd(
            redeemableUsd
        );

        return _min(collateralAmount, redeemableCollateral);
    }

    /// @dev Computes the maximum additional debt an actor can take on without going underwater.
    function _maxBorrowableByHealth(
        address actor
    ) internal view returns (uint256) {
        uint256 collateralUsd = lendingPool.getCollateralValue(actor);
        if (collateralUsd == 0) return 0;

        uint256 debt = lendingPool.getBorrowerDebt(actor);
        uint256 maxDebtAllowed = (collateralUsd * LIQUIDATION_THRESHOLD) /
            LIQUIDATION_PRECISION;

        if (maxDebtAllowed <= debt) return 0;
        return maxDebtAllowed - debt;
    }

    /// @dev Deterministically creates or selects an actor based on `actorSeed`.
    ///      1-in-ACTOR_DISCRIMINATOR chance of creating a new actor; otherwise reuses existing.
    function _getActor(uint256 actorSeed) internal returns (address actor) {
        if (s_actors.length > 0 && actorSeed % ACTOR_DISCRIMINATOR != 0) {
            return s_actors[actorSeed % s_actors.length];
        }

        actor = address(
            uint160(uint256(keccak256(abi.encode(actorSeed, s_actors.length))))
        );
        if (actor == address(0)) {
            actor = address(1);
        }

        if (!s_isKnownActor[actor]) {
            s_isKnownActor[actor] = true;
            s_actors.push(actor);
        }
    }

    /// @dev Ensures `actor` has at least `amount` USDC and has approved the pool.
    function _mintAndApproveUsdc(address actor, uint256 amount) internal {
        uint256 balance = usdc.balanceOf(actor);
        if (balance < amount) {
            usdc.mint(actor, amount - balance);
        }

        vm.prank(actor);
        usdc.approve(address(lendingPool), type(uint256).max);
    }

    /// @dev Ensures `actor` has at least `amount` WETH and has approved the pool.
    function _mintAndApproveWeth(address actor, uint256 amount) internal {
        uint256 balance = weth.balanceOf(actor);
        if (balance < amount) {
            weth.mint(actor, amount - balance);
        }

        vm.prank(actor);
        weth.approve(address(lendingPool), type(uint256).max);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev Ceiling division: ⌈numerator / denominator⌉.
    function _ceilDiv(
        uint256 numerator,
        uint256 denominator
    ) internal pure returns (uint256) {
        return numerator == 0 ? 0 : ((numerator - 1) / denominator) + 1;
    }
}
