// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LendingPool} from "../../../src/LendingPool.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployLendingPool} from "../../../script/DeployLendingPool.s.sol";
import {FakeERC20} from "../../mocks/FakeERC20.sol";
import {FailOnRevertHandler} from "./FailOnRevertHandler.t.sol";
import {InterestLib} from "../../../src/libraries/InterestLib.sol";

/// @title FailOnRevertInvariants
/// @notice Invariant test suite that runs with `fail_on_revert = true`.
/// @dev Because the handler carefully bounds every call to avoid reverts, ALL invariant
///      checks run after VALID state transitions only. This gives high confidence that no
///      legal sequence of operations can break protocol invariants.
///
///      Invariants tested (9 total):
///        1. Protocol balance ≥ protocolReserve
///        2. totalLiquidity ≥ totalBorrowed
///        3. Interest indexes ≥ starting value and lastUpdate ≤ block.timestamp
///        4. All view getters never revert
///        5. Contract balance ≥ (totalLiquidity − totalBorrowed) + protocolReserve  (solvency)
///        6. Borrow index ≥ liquidity index  (reserve factor guarantee)
///        7. All borrowers have health factor ≥ 1e18
///        8. Utilisation ≤ 100 %
///        9. Indexes are monotonically non-decreasing
/// forge-config: default.invariant.fail_on_revert = true
contract FailOnRevertInvariants is StdInvariant, Test {
    uint256 private constant STARTING_INDEX = 1e18;
    uint256 private constant PRECISION = 1e18;

    LendingPool public lendingPool;
    HelperConfig public helperConfig;
    FakeERC20 public usdc;
    FakeERC20 public weth;
    FailOnRevertHandler public handler;

    function setUp() external {
        DeployLendingPool deployer = new DeployLendingPool();
        (lendingPool, helperConfig) = deployer.run();
        usdc = FakeERC20(lendingPool.getUnderlyingAssetAddress());
        weth = FakeERC20(lendingPool.getCollateralAddress());
        handler = new FailOnRevertHandler(lendingPool, address(this));
        targetContract(address(handler));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Original Invariants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The pool's USDC balance must always be ≥ the recorded protocolReserve.
    function invariant_protocolMustHaveBalanceToCoverProtocolReserve()
        external
        view
    {
        uint256 protocolBalance = FakeERC20(usdc).balanceOf(
            address(lendingPool)
        );
        uint256 protocolReserve = lendingPool.getProtocolReserve();
        assertGe(protocolBalance, protocolReserve);
    }

    /// @notice Total deposited liquidity must always be ≥ total outstanding borrows.
    function invariant_totalLiquidityMustAlwaysExceedTotalBorrowed()
        external
        view
    {
        uint256 totalLiquidity = lendingPool.getTotalLiquidity();
        uint256 totalBorrowed = lendingPool.getTotalBorrowed();
        assertGe(totalLiquidity, totalBorrowed);
    }

    /// @notice Both interest indexes must remain ≥ their starting value (1e18)
    ///         and their lastUpdate must never be in the future.
    function invariant_interestIndexesStayInitialized() external view {
        LendingPool.InterestIndex memory liquidityIndex = lendingPool
            .getLiquidityIndex();
        LendingPool.InterestIndex memory borrowIndex = lendingPool
            .getBorrowIndex();

        assertGe(liquidityIndex.index, STARTING_INDEX);
        assertGe(borrowIndex.index, STARTING_INDEX);
        assertLe(liquidityIndex.lastUpdate, block.timestamp);
        assertLe(borrowIndex.lastUpdate, block.timestamp);
    }

    /// @notice Every public/external view getter must be callable without reverting,
    ///         regardless of pool state.
    function invariant_gettersNeverRevert() external view {
        _assertGettersNeverRevertFor(address(0));
        _assertGettersNeverRevertFor(address(this));
        _assertGettersNeverRevertFor(address(handler));

        uint256 actorsLength = handler.getActorsLength();
        if (actorsLength > 0) {
            address actor = handler.getActorAt(block.number);
            _assertGettersNeverRevertFor(actor);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  New Invariants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Solvency: the contract must physically hold enough USDC to cover
    ///         net lender deposits plus protocol reserves.
    /// @dev `contractBalance ≥ (totalLiquidity − totalBorrowed) + protocolReserve`
    function invariant_solvencyTokenBalanceCoversObligations() external view {
        uint256 contractBalance = usdc.balanceOf(address(lendingPool));
        uint256 totalLiquidity = lendingPool.getTotalLiquidity();
        uint256 totalBorrowed = lendingPool.getTotalBorrowed();
        uint256 protocolReserve = lendingPool.getProtocolReserve();

        uint256 minRequired = (totalLiquidity - totalBorrowed) +
            protocolReserve;
        assertGe(
            contractBalance,
            minRequired,
            "Contract balance insufficient to cover lender deposits + reserves"
        );
    }

    /// @notice The borrow index must always be ≥ the liquidity index because borrowers
    ///         pay strictly more interest than lenders receive (reserve factor skims the diff).
    function invariant_borrowIndexGeLiquidityIndex() external view {
        LendingPool.InterestIndex memory liquidityIndex = lendingPool
            .getLiquidityIndex();
        LendingPool.InterestIndex memory borrowIndex = lendingPool
            .getBorrowIndex();

        assertGe(
            borrowIndex.index,
            liquidityIndex.index,
            "Borrow index fell below liquidity index"
        );
    }

    /// @notice After every valid handler call, every known borrower must have
    ///         health factor ≥ 1e18 (the pool reverts any action that would break this).
    function invariant_allBorrowersHealthy() external view {
        address[] memory actors = handler.getActors();
        for (uint256 i = 0; i < actors.length; i++) {
            uint256 debt = lendingPool.getBorrowerDebt(actors[i]);
            if (debt > 0) {
                uint256 healthFactor = lendingPool.getHealthFactor(actors[i]);
                assertGe(
                    healthFactor,
                    PRECISION,
                    "Borrower has broken health factor"
                );
            }
        }
    }

    /// @notice Utilisation ratio must never exceed 100 %.
    /// @dev `totalBorrowed * 1e18 / totalLiquidity ≤ 1e18`
    function invariant_utilizationNeverExceeds100Percent() external view {
        uint256 totalLiquidity = lendingPool.getTotalLiquidity();
        uint256 totalBorrowed = lendingPool.getTotalBorrowed();

        if (totalLiquidity > 0) {
            uint256 utilization = (totalBorrowed * PRECISION) / totalLiquidity;
            assertLe(utilization, PRECISION, "Utilization exceeded 100%");
        } else {
            assertEq(totalBorrowed, 0, "Borrowed exists without liquidity");
        }
    }

    /// @notice Interest indexes must never decrease between handler calls.
    /// @dev Compares on-chain indexes against the ghost snapshots taken after each action.
    function invariant_indexesMonotonicallyNonDecreasing() external view {
        LendingPool.InterestIndex memory liquidityIndex = lendingPool
            .getLiquidityIndex();
        LendingPool.InterestIndex memory borrowIndex = lendingPool
            .getBorrowIndex();

        assertGe(
            liquidityIndex.index,
            handler.ghost_previousLiquidityIndex(),
            "Liquidity index decreased"
        );
        assertGe(
            borrowIndex.index,
            handler.ghost_previousBorrowerIndex(),
            "Borrower index decreased"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Verifies that every view/pure getter on LendingPool can be called without reverting.
    function _assertGettersNeverRevertFor(address user) internal view {
        _assertNoRevert(
            abi.encodeCall(LendingPool.getLiquidationThreshold, ())
        );
        _assertNoRevert(abi.encodeCall(LendingPool.getProtocolReserve, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getHealthFactor, (user)));
        _assertNoRevert(
            abi.encodeCall(LendingPool.getUnderlyingAssetAddress, ())
        );
        _assertNoRevert(abi.encodeCall(LendingPool.getTotalLiquidity, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getTotalBorrowed, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getCollateralAddress, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getDepositAmount, (user)));
        _assertNoRevert(abi.encodeCall(LendingPool.getLiquidityIndex, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getBorrowIndex, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getCollateralValue, (user)));
        _assertNoRevert(abi.encodeCall(LendingPool.getLenderInterestRate, ()));
        _assertNoRevert(
            abi.encodeCall(LendingPool.getTokenAmountFromUsd, (1e18))
        );
        _assertNoRevert(abi.encodeCall(LendingPool.getLiquidityAvailable, ()));
        _assertNoRevert(abi.encodeCall(LendingPool.getUsdValue, (1e18)));
        _assertNoRevert(
            abi.encodeCall(LendingPool.previewCurrentLiquidityIndex, ())
        );
        _assertNoRevert(
            abi.encodeCall(LendingPool.previewCurrentBorrowerIndex, ())
        );
        _assertNoRevert(abi.encodeCall(LendingPool.getBorrowerDebt, (user)));
    }

    /// @dev Low-level staticcall wrapper — asserts the call succeeds.
    function _assertNoRevert(bytes memory callData) internal view {
        (bool success, ) = address(lendingPool).staticcall(callData);
        assertTrue(success);
    }
}
