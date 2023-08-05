// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "../lib/forge-std/src/Test.sol";
import {StdCheats} from "../lib/forge-std/src/StdCheats.sol";
import {Hinnycoin} from "../src/Hinnycoin.sol";
import {HNCEngine} from "../src/HNCEngine.sol";
import {DeployHinnycoin} from "../script/DeployHinnycoin.s.sol";
import {CorollaryFunctions} from "../script/CorollaryFunctions.s.sol";
import {ERC20Mock} from "../lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../script/mocks/MockV3Aggregator.s.sol";

contract HNCEngineTest is StdCheats, Test {
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    );

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public collateralToCover = 20 ether;
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    address public USER = makeAddr("BOB");
    address public USER2 = makeAddr("ALICE");

    DeployHinnycoin deployer;
    HNCEngine hncEngine;
    Hinnycoin hnc;
    CorollaryFunctions corollary;

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(hncEngine), amountCollateral);
        hncEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployHinnycoin();
        (hncEngine, hnc, corollary) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = corollary
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
    }

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(
            HNCEngine
                .HNCEngine__TokenAddressesAndPriceFeedAddressesShouldHaveSameLength
                .selector
        );
        new HNCEngine(tokenAddresses, priceFeedAddresses, address(hnc));
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 1e18;
        uint256 expectedUsd = 2000e18;
        uint256 usdValue = hncEngine.tokenPriceToUsd(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = hncEngine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(hncEngine), amountCollateral);

        vm.expectRevert(HNCEngine.HNCEngine__MustBeMoreThanZero.selector);
        hncEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock token = new ERC20Mock("Coin", "Coin", USER, amountCollateral);
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                HNCEngine.HNCEngine__TokenNotAllowedAsCollateral.selector,
                address(token)
            )
        );
        hncEngine.depositCollateral(address(token), amountCollateral);
        vm.stopPrank();
    }

    function testCanDepositCollateralWithoutMinting()
        public
        depositedCollateral
    {
        uint256 userBalance = hnc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalHNCMinted, uint256 collateralValueInUsd) = hncEngine
            .getAccountInfo(USER);
        uint256 expectedDepositedAmount = hncEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalHNCMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    function testRevertNullAmountToMint() public depositedCollateral {
        vm.expectRevert(HNCEngine.HNCEngine__MustBeMoreThanZero.selector);
        hncEngine.mintHNC(0);
    }

    function testMint() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amount = 10;
        hncEngine.mintHNC(amount);

        assertEq(hnc.balanceOf(USER), amount);
        vm.stopPrank();
    }

    function testBurningMoreThanBalance() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert();
        uint256 amountBurned = 1;
        hncEngine.burnHNC(amountBurned);
        vm.stopPrank();
    }

    function testRevertMintingNotAllowedMintingForHealthReasons() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (amountCollateral *
                (uint256(price) * hncEngine.getAdditionalFeedPrecision())) /
            hncEngine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(hncEngine), amountCollateral);
        hncEngine.depositCollateral(weth, amountCollateral);

        uint256 expectedHealthFactor = hncEngine.calculateHealthFactor(
            amountToMint,
            hncEngine.getUsdValue(amountCollateral, weth)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                HNCEngine.HNCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        hncEngine.mintHNC(amountToMint);
        vm.stopPrank();
    }

    function testRevertRedeemCollateralZeroCollateral()
        public
        depositedCollateral
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                HNCEngine.HNCEngine__MustBeMoreThanZero.selector
            )
        );
        hncEngine.redeemCollateral(weth, 0);
    }

    function testRedeem() public depositedCollateral {
        vm.startPrank(USER);
        hncEngine.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();
    }

    function testHealthFactorIsCorrect() public depositedCollateral {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        vm.startPrank(USER);
        uint256 collateralInUsd = (amountCollateral *
            (uint256(price) * hncEngine.getAdditionalFeedPrecision())) /
            hncEngine.getPrecision();
        uint256 mintedAmount = 1;
        uint256 expectedHF = hncEngine.calculateHealthFactor(
            mintedAmount,
            hncEngine.getUsdValue(amountCollateral, weth)
        );

        hncEngine.mintHNC(mintedAmount);
        uint256 HF = hncEngine.healthFactor(mintedAmount, collateralInUsd);

        assertEq(HF, expectedHF);
        vm.stopPrank();
    }

    function testRevertLiquidateNullAmount() public depositedCollateral {
        vm.expectRevert(
            abi.encodeWithSelector(
                HNCEngine.HNCEngine__MustBeMoreThanZero.selector
            )
        );
        hncEngine.liquidate(weth, USER, 0);
    }

    function testRevertLiquidateWithGoodHealthFactor()
        public
        depositedCollateral
    {
        vm.expectRevert(
            abi.encodeWithSelector(HNCEngine.HNCEngine__HealthFactorOk.selector)
        );
        hncEngine.liquidate(weth, USER, 1);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(hncEngine), amountCollateral);
        hncEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = hncEngine.getCollateralAccountValueInUsd(
            USER
        );
        uint256 expectedCollateralValue = hncEngine.getUsdValue(
            amountCollateral,
            weth
        );
        assertEq(collateralValue, expectedCollateralValue);
    }
}
