// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../../src/LendingPool.sol";
import {FakeERC20} from "../../mocks/FakeERC20.sol";

/// @title ContinueOnRevertHandler
/// @notice Handler contract for the continue-on-revert invariant test suite.
/// @dev Unlike the fail-on-revert handler, this handler uses LOOSER bounds on inputs
///      (e.g. `borrowToken` doesn't check health factor headroom). Calls that produce
///      invalid state will revert inside LendingPool and be swallowed by the fuzzer.
///      This approach catches edge cases that the fail-on-revert handler's bounding might mask,
///      at the cost of many calls being no-ops (reverted).
///
///      Ghost variables and actor management are identical to `FailOnRevertHandler`.
contract ContinueOnRevertHandler is Test {
    LendingPool public immutable lendingPool;
    FakeERC20 public immutable usdc;
    FakeERC20 public immutable weth;
    address public immutable protocolOperator;

    uint256 private constant MAX_TOKEN_AMOUNT = 1_000_000_000e18;
    uint256 private constant ACTOR_DISCRIMINATOR = 4;

    address[] private s_actors;
    mapping(address actor => bool isKnown) private s_isKnownActor;

    // ── Ghost variables for index monotonicity invariant ─────────────────
    uint256 public ghost_previousLiquidityIndex;
    uint256 public ghost_previousBorrowerIndex;

    constructor(LendingPool _lendingPool, address _protocolOperator) {
        lendingPool = _lendingPool;
        protocolOperator = _protocolOperator;
        usdc = FakeERC20(lendingPool.getUnderlyingAssetAddress());
        weth = FakeERC20(lendingPool.getCollateralAddress());

        ghost_previousLiquidityIndex = lendingPool.getLiquidityIndex().index;
        ghost_previousBorrowerIndex = lendingPool.getBorrowIndex().index;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Handler actions — loosely bounded, reverts are expected and swallowed
    // ═══════════════════════════════════════════════════════════════════════

    function depositToken(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1, MAX_TOKEN_AMOUNT);

        _mintAndApproveUsdc(actor, amount);

        vm.prank(actor);
        lendingPool.depositToken(amount);
        _updateGhostIndexes();
    }

    /// @dev Does NOT check available liquidity — may revert inside LendingPool.
    function withdrawToken(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 userDeposit = lendingPool.getDepositAmount(actor);
        if (userDeposit == 0) return;

        amount = bound(amount, 1, userDeposit);

        vm.prank(actor);
        lendingPool.withdrawToken(amount);
        _updateGhostIndexes();
    }

    /// @dev Guards against empty actor set to avoid div-by-zero, but does NOT
    ///      check health factor — the liquidate call may revert.
    function liquidate(
        uint256 liquidatorSeed,
        uint256 borrowerSeed,
        uint256 debtToCover
    ) external {
        if (s_actors.length == 0) return;

        address liquidator = _getActor(liquidatorSeed);
        uint256 borrowerIndex = borrowerSeed % s_actors.length;
        address borrower = s_actors[borrowerIndex];
        if (borrower == liquidator && s_actors.length > 1) {
            borrower = s_actors[(borrowerIndex + 1) % s_actors.length];
        }

        uint256 borrowerDebt = lendingPool.getBorrowerDebt(borrower);
        if (borrowerDebt == 0) return;
        debtToCover = bound(debtToCover, 1, borrowerDebt);

        _mintAndApproveUsdc(liquidator, debtToCover);

        vm.prank(liquidator);
        lendingPool.liquidate(borrower, debtToCover);
        _updateGhostIndexes();
    }

    /// @dev Does NOT check health factor — borrow may revert if under-collateralised.
    function depositCollateralAndBorrowToken(
        uint256 actorSeed,
        uint256 amountCollateral,
        uint256 amountToBorrow
    ) external {
        address actor = _getActor(actorSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_TOKEN_AMOUNT);
        amountToBorrow = bound(amountToBorrow, 1, MAX_TOKEN_AMOUNT);

        _mintAndApproveWeth(actor, amountCollateral);

        vm.prank(actor);
        lendingPool.depositCollateralAndBorrowToken(
            amountCollateral,
            amountToBorrow
        );
        _updateGhostIndexes();
    }

    /// @dev Does NOT check health factor after collateral redemption — may revert.
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
        amountCollateralToRedeem = bound(
            amountCollateralToRedeem,
            1,
            collateralAmount
        );

        _mintAndApproveUsdc(actor, amountDebtToRepay);

        vm.prank(actor);
        lendingPool.repayDebtAndRedeemCollateral(
            amountDebtToRepay,
            amountCollateralToRedeem
        );
        _updateGhostIndexes();
    }

    function withdrawProtocolReserves(uint256 toSeed, uint256 amount) external {
        uint256 reserve = lendingPool.getProtocolReserve();
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        address to = _getActor(toSeed);

        vm.prank(protocolOperator);
        lendingPool.withdrawProtocolReserves(to, amount);
        _updateGhostIndexes();
    }

    function depositCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1, MAX_TOKEN_AMOUNT);

        _mintAndApproveWeth(actor, amount);

        vm.prank(actor);
        lendingPool.depositCollateral(amount);
        _updateGhostIndexes();
    }

    /// @dev Does NOT check health factor or liquidity — may revert.
    function borrowToken(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);
        amount = bound(amount, 1, MAX_TOKEN_AMOUNT);

        vm.prank(actor);
        lendingPool.borrowToken(amount);
        _updateGhostIndexes();
    }

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

    /// @dev Does NOT check health factor — may revert.
    function redeemCollateral(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 collateralUsd = lendingPool.getCollateralValue(actor);
        if (collateralUsd == 0) return;

        uint256 collateralAmount = lendingPool.getTokenAmountFromUsd(
            collateralUsd
        );
        if (collateralAmount == 0) return;
        amount = bound(amount, 1, collateralAmount);

        vm.prank(actor);
        lendingPool.redeemCollateral(amount);
        _updateGhostIndexes();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  View helpers
    // ═══════════════════════════════════════════════════════════════════════

    function getActorsLength() external view returns (uint256) {
        return s_actors.length;
    }

    function getActorAt(uint256 index) external view returns (address) {
        if (s_actors.length == 0) return address(0);
        return s_actors[index % s_actors.length];
    }

    function getActors() external view returns (address[] memory) {
        return s_actors;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  Internal helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _updateGhostIndexes() internal {
        ghost_previousLiquidityIndex = lendingPool.getLiquidityIndex().index;
        ghost_previousBorrowerIndex = lendingPool.getBorrowIndex().index;
    }

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

    function _mintAndApproveUsdc(address actor, uint256 amount) internal {
        uint256 balance = usdc.balanceOf(actor);
        if (balance < amount) {
            usdc.mint(actor, amount - balance);
        }

        vm.prank(actor);
        usdc.approve(address(lendingPool), type(uint256).max);
    }

    function _mintAndApproveWeth(address actor, uint256 amount) internal {
        uint256 balance = weth.balanceOf(actor);
        if (balance < amount) {
            weth.mint(actor, amount - balance);
        }

        vm.prank(actor);
        weth.approve(address(lendingPool), type(uint256).max);
    }
}
