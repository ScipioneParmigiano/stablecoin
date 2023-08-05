// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {StdCheats} from "lib/forge-std/src/StdCheats.sol";
import {Hinnycoin} from "src/Hinnycoin.sol";
import {HNCEngine} from "src/HNCEngine.sol";
import {DeployHinnycoin} from "script/DeployHinnycoin.s.sol";
import {CorollaryFunctions} from "script/CorollaryFunctions.s.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "script/mocks/MockV3Aggregator.s.sol";

contract Handler is Test {
    HNCEngine hncEngine;
    Hinnycoin hnc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    address[] public users;

    constructor(HNCEngine _hncEngine, Hinnycoin _hnc) {
        hnc = _hnc;
        hncEngine = _hncEngine;

        address[] memory collateralTokens = hncEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(
            hncEngine.getCollateralTokenPriceFeed(address(weth))
        );
        btcUsdPriceFeed = MockV3Aggregator(
            hncEngine.getCollateralTokenPriceFeed(address(wbtc))
        );
    }

    function depositCollateral(
        uint256 collateralSeet,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeet);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(hncEngine), amountCollateral);
        hncEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(
        uint256 collateralSeet,
        uint256 amountToRedeem
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeet);
        uint256 maxCollateralToRedeem = hncEngine.getCollateralBalanceOfUser(
            msg.sender,
            address(collateral)
        );
        amountToRedeem = bound(amountToRedeem, 0, maxCollateralToRedeem);
        if (amountToRedeem == 0) return;
        vm.startPrank(msg.sender);
        hncEngine.redeemCollateral(address(collateral), amountToRedeem);
        vm.stopPrank();
    }

    function mintHNC(uint256 amountToBeMinted, uint256 addressSeed) public {
        if (users.length == 0) return;
        address sender = users[addressSeed % users.length];
        (uint256 totalHNCminted, uint256 collateralValueInUsd) = hncEngine
            .getAccountInfo(msg.sender);
        int256 maxToMint = int256(collateralValueInUsd / 2 - totalHNCminted);
        if (maxToMint < 0) return;

        amountToBeMinted = bound(amountToBeMinted, 0, uint256(maxToMint));
        if (amountToBeMinted == 0) return;

        vm.startPrank(sender);
        hncEngine.mintHNC(amountToBeMinted);
        vm.stopPrank();
    }

    function liquidate(
        uint256 collateralSeed,
        address userToBeLiquidated,
        uint256 debtToCover
    ) public {
        uint256 minHealthFactor = hncEngine.getMinHealthFactor();
        uint256 userHealthFactor = hncEngine.getHealthFactor(
            userToBeLiquidated
        );
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        hncEngine.liquidate(
            address(collateral),
            userToBeLiquidated,
            debtToCover
        );
    }

    function updateCollateral(uint64 newPrice) public {
        ethUsdPriceFeed.updateAnswer(int256(uint256(newPrice)));
    }

    function burnHNC(uint256 amountHNC) public {
        // Must burn more than 0
        amountHNC = bound(amountHNC, 0, hnc.balanceOf(msg.sender));
        if (amountHNC == 0) {
            return;
        }
        hncEngine.burnHNC(amountHNC);
    }

    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) return weth;
        return wbtc;
    }
}
