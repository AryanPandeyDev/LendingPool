// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Script} from "../lib/forge-std/src/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployLendingPool is Script {
    function run() external returns (LendingPool, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();

        (
            address underlyingAssetAddress,
            address collateralAddress,
            uint256 baseRate,
            uint256 slope,
            uint256 baseRateAtKink,
            uint256 slopeAtKink,
            uint256 reserveFactor,
            address priceFeedAddress
        ) = helperConfig.activeConfig();

        vm.startBroadcast();
        LendingPool lendingPool = new LendingPool(
            underlyingAssetAddress,
            collateralAddress,
            baseRate,
            slope,
            baseRateAtKink,
            slopeAtKink,
            reserveFactor,
            priceFeedAddress
        );
        vm.stopBroadcast();

        return (lendingPool, helperConfig);
    }
}
