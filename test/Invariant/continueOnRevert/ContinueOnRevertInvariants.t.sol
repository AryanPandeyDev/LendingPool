//SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LendingPool} from "../../../src/LendingPool.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployLendingPool} from "../../../script/DeployLendingPool.s.sol";
import {FakeERC20} from "../../mocks/FakeERC20.sol";
import {ContinueOnRevertHandler} from "./ContinueOnRevertHandler.t.sol";
import {InterestLib} from "../../../src/libraries/InterestLib.sol";

/// @title ContinueOnRevertInvariants
/// @notice Invariant test suite that runs with `fail_on_revert = false` (foundry.toml default).
/// @dev The handler uses loose bounds so many calls revert inside LendingPool and are
///      swallowed by the fuzzer. Invariants are only checked AFTER successful calls, so
///      this suite validates that reverted calls do not corrupt state in unexpected ways.
///
///      This suite tests the SAME 9 invariants as `FailOnRevertInvariants`.
contract ContinueOnRevertInvariants is StdInvariant, Test {
    uint256 private constant STARTING_INDEX = 1e18;
    uint256 private constant PRECISION = 1e18;

    LendingPool public lendingPool;
    HelperConfig public helperConfig;
    FakeERC20 public usdc;
    FakeERC20 public weth;
    ContinueOnRevertHandler public handler;

    function setUp() external {
        DeployLendingPool deployer = new DeployLendingPool();
        (lendingPool, helperConfig) = deployer.run();
        usdc = FakeERC20(lendingPool.getUnderlyingAssetAddress());
        weth = FakeERC20(lendingPool.getCollateralAddress());
        handler = new ContinueOnRevertHandler(lendingPool, address(this));
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

    /// @notice Interest indexes stay ≥ 1e18 and lastUpdate ≤ block.timestamp.
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

    /// @notice All view getters callable without reverting.
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

    /// @notice Solvency: contract balance ≥ (totalLiquidity − totalBorrowed) + protocolReserve.
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

    /// @notice Borrow index ≥ liquidity index (reserve factor guarantee).
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

    /// @notice All borrowers must have health factor ≥ 1e18 after any successful call.
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

    /// @notice Utilisation ≤ 100 %.
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

    /// @notice Indexes never decrease between calls.
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

    function _assertNoRevert(bytes memory callData) internal view {
        (bool success, ) = address(lendingPool).staticcall(callData);
        assertTrue(success);
    }
}
