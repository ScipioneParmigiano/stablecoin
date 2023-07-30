// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script} from "../lib/forge-std/src/Script.sol";
import {Hinnycoin} from "../src/Hinnycoin.sol";
import {HNCEngine} from "../src/HNCEngine.sol";
import {CorollaryFunctions} from "./CorollaryFunctions.s.sol";

contract DeployHinnycoin is Script {
    address[] public tokenAddresses;
    address[] public tokenPriceFeed;

    function run() public returns (HNCEngine, Hinnycoin, CorollaryFunctions) {
        CorollaryFunctions corollary = new CorollaryFunctions();

        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc,
            uint256 deployerKey
        ) = corollary.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        tokenPriceFeed = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        Hinnycoin hnc = new Hinnycoin();
        HNCEngine hncEngine = new HNCEngine(
            tokenAddresses,
            tokenPriceFeed,
            address(hnc)
        );

        hnc.transferOwnership(address(hncEngine));
        vm.stopBroadcast();
        return (hncEngine, hnc, corollary);
    }
}
