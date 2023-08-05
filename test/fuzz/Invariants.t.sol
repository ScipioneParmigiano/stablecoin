// SPDX-License-Identifier: MIT

// 1. total supply of HNC < total value of collateral
// 2. getter function should never revert

pragma solidity ^0.8.19;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {StdInvariant} from "lib/forge-std/src/StdInvariant.sol";
import {Hinnycoin} from "src/Hinnycoin.sol";
import {HNCEngine} from "src/HNCEngine.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "script/mocks/MockV3Aggregator.s.sol";
import {DeployHinnycoin} from "script/DeployHinnycoin.s.sol";
import {CorollaryFunctions} from "script/CorollaryFunctions.s.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {
    DeployHinnycoin deployer;
    HNCEngine hncEngine;
    Hinnycoin hnc;
    CorollaryFunctions corollary;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() public {
        deployer = new DeployHinnycoin();
        (hncEngine, hnc, corollary) = deployer.run();
        (, , weth, wbtc, ) = corollary.activeNetworkConfig();
        //targetContract(address(hncEngine));
        handler = new Handler(hncEngine, hnc);
        targetContract(address(handler));
    }

    function invariant_protocolMustBeOvercorrateralized() public view {
        uint256 totalHNCsupply = hnc.totalSupply();
        uint256 totalDepositedWETH = IERC20(weth).balanceOf(address(hncEngine));
        uint256 totalDepositedWBTC = IERC20(wbtc).balanceOf(address(hncEngine));

        uint256 collateralUsdValue = hncEngine.getUsdValue(
            totalDepositedWETH,
            weth
        ) + hncEngine.getUsdValue(totalDepositedWBTC, wbtc);

        assert(collateralUsdValue >= totalHNCsupply);
    }
}
