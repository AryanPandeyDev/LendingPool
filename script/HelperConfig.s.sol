// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Script} from "../lib/forge-std/src/Script.sol";
import {FakeERC20} from "../test/mocks/FakeERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract CodeConstant {
    // ─── Math constants ─────────────────────────────────────────────────
    uint256 constant PRECISION = 1e18;
    uint256 constant KINK = 80e16; // 80%

    // ─── Network addresses ──────────────────────────────────────────────
    // USDC
    address constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    // WETH (collateral)
    address constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant SEPOLIA_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    // ETH/USD Chainlink Price Feed
    address constant MAINNET_ETH_USD_PRICE_FEED =
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant SEPOLIA_ETH_USD_PRICE_FEED =
        0x694AA1769357215DE4FAC081bf1f309aDC325306;

    // Mock price feed defaults
    uint8 constant PRICE_FEED_DECIMALS = 8;
    int256 constant ETH_USD_PRICE = 2000e8;

    // ─── Chain IDs ──────────────────────────────────────────────────────
    uint256 constant ETH_MAINNET_CHAIN_ID = 1;
    uint256 constant ETH_SEPOLIA_CHAIN_ID = 11155111;

    // ─── Default interest rate parameters ───────────────────────────────
    uint256 constant BASE_RATE = 2e16; // 2%
    uint256 constant SLOPE = 8e16; // 8%
    uint256 constant BASE_RATE_AT_KINK = 10e16; // 10%
    uint256 constant SLOPE_AT_KINK = 100e16; // 100%
    uint256 constant RESERVE_FACTOR = 5e16; // 5%
}

contract HelperConfig is Script, CodeConstant {
    struct NetworkConfig {
        address underlyingAssetAddress;
        address collateralAddress;
        uint256 baseRate;
        uint256 slope;
        uint256 baseRateAtKink;
        uint256 slopeAtKink;
        uint256 reserveFactor;
        address priceFeedAddress;
    }

    NetworkConfig public activeConfig;

    constructor() {
        if (block.chainid == ETH_MAINNET_CHAIN_ID) {
            activeConfig = getMainnetConfig();
        } else if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            activeConfig = getSepoliaConfig();
        } else {
            activeConfig = getOrCreateAnvilConfig();
        }
    }

    function getMainnetConfig() internal pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                underlyingAssetAddress: MAINNET_USDC,
                collateralAddress: MAINNET_WETH,
                baseRate: BASE_RATE,
                slope: SLOPE,
                baseRateAtKink: BASE_RATE_AT_KINK,
                slopeAtKink: SLOPE_AT_KINK,
                reserveFactor: RESERVE_FACTOR,
                priceFeedAddress: MAINNET_ETH_USD_PRICE_FEED
            });
    }

    function getSepoliaConfig() internal pure returns (NetworkConfig memory) {
        return
            NetworkConfig({
                underlyingAssetAddress: SEPOLIA_USDC,
                collateralAddress: SEPOLIA_WETH,
                baseRate: BASE_RATE,
                slope: SLOPE,
                baseRateAtKink: BASE_RATE_AT_KINK,
                slopeAtKink: SLOPE_AT_KINK,
                reserveFactor: RESERVE_FACTOR,
                priceFeedAddress: SEPOLIA_ETH_USD_PRICE_FEED
            });
    }

    function getOrCreateAnvilConfig() internal returns (NetworkConfig memory) {
        if (activeConfig.underlyingAssetAddress != address(0)) {
            return activeConfig;
        }

        vm.startBroadcast();
        FakeERC20 fakeUsdc = new FakeERC20("Fake USDC", "fUSDC");
        FakeERC20 fakeWeth = new FakeERC20("Fake WETH", "fWETH");
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(
            PRICE_FEED_DECIMALS,
            ETH_USD_PRICE
        );
        vm.stopBroadcast();

        return
            NetworkConfig({
                underlyingAssetAddress: address(fakeUsdc),
                collateralAddress: address(fakeWeth),
                baseRate: BASE_RATE,
                slope: SLOPE,
                baseRateAtKink: BASE_RATE_AT_KINK,
                slopeAtKink: SLOPE_AT_KINK,
                reserveFactor: RESERVE_FACTOR,
                priceFeedAddress: address(mockPriceFeed)
            });
    }
}
