// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title ILendingPool
/// @notice External interface for the LendingPool contract.
/// @dev Includes all public / external function signatures, custom errors, events, and structs
///      needed by frontends, periphery contracts, and off-chain integrations.
interface ILendingPool {
    ///////////////////
    // Errors
    ///////////////////

    error LendingPool__AmountMustBeMoreThanZero();
    error LendingPool__TransferFailed();
    error LendingPool__NotEnoughLiquidityAvailable();
    error LendingPool__HealthFactorBroken(uint256 healthFactor);
    error LendingPool__HealthFactorOk();
    error LendingPool__HealthFactorNotImproved();
    error LendingPool__CallerNotAuthorized();

    ///////////////////
    // Events
    ///////////////////

    event TokenDeposited(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event TokenBorrowed(address indexed user, uint256 amount);
    event TokenWithdrawn(address indexed user, uint256 amount);
    event DebtRepaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtCovered,
        uint256 collateralSeized
    );
    event CollateralRedeemed(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    ///////////////////
    // Structs
    ///////////////////

    /// @notice Cumulative interest index with its last-update timestamp.
    struct InterestIndex {
        uint256 index;
        uint256 lastUpdate;
    }

    ///////////////////
    // Core Actions
    ///////////////////

    function depositToken(uint256 amount) external;

    function withdrawToken(uint256 amount) external;

    function liquidate(address user, uint256 debtToCover) external;

    function depositCollateralAndBorrowToken(
        uint256 amountCollateral,
        uint256 amountToBorrow
    ) external;

    function repayDebtAndRedeemCollateral(
        uint256 amountDebtToRepay,
        uint256 amountCollateralToRedeem
    ) external;

    function withdrawProtocolReserves(address to, uint256 amount) external;

    function depositCollateral(uint256 amount) external;

    function borrowToken(uint256 amount) external;

    function repayDebt(uint256 amount) external;

    function redeemCollateral(uint256 amount) external;

    ///////////////////
    // View / Pure Helpers
    ///////////////////

    function getTokenAmountFromUsd(
        uint256 usdAmount
    ) external view returns (uint256);

    function getLiquidityAvailable() external view returns (uint256);

    function getUsdValue(uint256 amount) external view returns (uint256);

    function previewCurrentLiquidityIndex()
        external
        view
        returns (InterestIndex memory);

    function previewCurrentBorrowerIndex()
        external
        view
        returns (InterestIndex memory);

    function getBorrowerDebt(address user) external view returns (uint256);

    function getProtocolReserve() external view returns (uint256);

    function getHealthFactor(address user) external view returns (uint256);

    function getUnderlyingAssetAddress() external view returns (address);

    function getTotalLiquidity() external view returns (uint256);

    function getTotalBorrowed() external view returns (uint256);

    function getCollateralAddress() external view returns (address);

    function getDepositAmount(address user) external view returns (uint256);

    function getLiquidityIndex() external view returns (InterestIndex memory);

    function getBorrowIndex() external view returns (InterestIndex memory);

    function getCollateralValue(address user) external view returns (uint256);

    function getLenderInterestRate() external view returns (uint256);

    function getBorrowerInterestRate() external view returns (uint256);

    function getProtocolOperator() external view returns (address);

    function getLiquidationThreshold() external pure returns (uint256);
}
