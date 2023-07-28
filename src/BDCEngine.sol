// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Bardottocoin} from "src/Bardottocoin.sol";
import {BDCEngineInterface} from "src/BDCEngineInterface.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

//@author: Pietro Zanotta
//@title: BDCEngine
//@description: The following contract regulates the Bardottoin stablecoin,
//              which is collateralized by wETH and wBTC and whose price is anchored
//              to 1 USD.

/*is BDCEngineInterface*/ contract BDCEngine {
    /*
     *** Errors ***
     */
    error BDCEngine__MustBeMoreThanZero();
    error BDCEngine__TokenAddressesAndPriceFeedAddressesShouldHaveSameLength();
    error BDCEngine__TokenNotAllowedAsCollateral();
    error BDCEngine__TransferFailed();
    error BDCEngine__BreaksHealthFactor(uint256 healthFactor);
    /*
     *** Event ***
     */

    event CollateralDeposited(address sender, address token, uint256 amout);

    /*
     *** Variables ***
     */
    Bardottocoin private immutable i_bdc;
    mapping(address => address) private s_tokenToPriceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address => uint256) private s_BDCMinted;
    address[] private s_collateralTokens;
    uint256 constant LIQUIDATION_THRESHOLD = 50; // 200%
    uint256 constant LIQUIDATION_PRECISION = 100;
    uint256 constant PRECISION = 100;
    uint256 constant MIN_HEALTH_FACTOR = 1;

    /*
     *** Modifiers ***
     */
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert BDCEngine__MustBeMoreThanZero();
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_tokenToPriceFeeds[tokenAddress] == address(0)) {
            revert BDCEngine__TokenNotAllowedAsCollateral();
        }
        _;
    }

    /*
     *** Functions ***
     */

    constructor(
        address[] memory _tokenAddresses,
        address[] memory _priceFeedAddresses,
        address _bdcAddress
    ) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert BDCEngine__TokenAddressesAndPriceFeedAddressesShouldHaveSameLength();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_tokenToPriceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_bdc = Bardottocoin(_bdcAddress);
    }

    //@param: tokenCollateralAddress is the address of the token to deposit as collateral (e.g. wETH)
    //@param: amountCollateral is the amount of collateral to deposit
    function depositCollater(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) external moreThanZero(_amountCollateral) {
        s_collateralDeposited[msg.sender][
            _tokenCollateralAddress
        ] += _amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool success = IERC20(_tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            _amountCollateral
        );
        if (!success) revert BDCEngine__TransferFailed();
    }

    //@param: amount of Bardottocoin to mint. It has to be overcollateralized
    function mintBDC(
        uint256 _amountBDCToMint
    ) external moreThanZero(_amountBDCToMint) {
        s_BDCMinted[msg.sender] += _amountBDCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function depositCollateralAndMintBDC() external {}

    function redeemCollateral() external {}

    function redeemCollateralForBDC() external {}

    function burnBDC() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    //@description: function to get the price of tokens in USD
    function _tokenPriceToUsd(
        address _token,
        uint256 _amount
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeeds[_token]
        );

        (, , , uint256 price, ) = priceFeed.latestRoundData();
        return ((price * 1e10) * _amount) / PRECISION;
    }

    //@description: give the value of the supplies collateral
    function getCollateralAccountValueInUsd(
        address _user
    ) public view returns (uint256) {
        uint256 totalCollateralValueInUsd;
        for (uint256 i; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[_user][token];

            totalCollateralValueInUsd += _tokenPriceToUsd(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    //@description: returns the number of BDC minteb by the user and the value in usd of it's collateral
    function _getAccountInfo(
        address _user
    ) private view returns (uint256, uint256) {
        uint256 collateralValueInUsd = getCollateralAccountValueInUsd(_user);
        uint256 bdcMinted = s_BDCMinted[_user];
        return (bdcMinted, collateralValueInUsd);
    }

    //@description: calculate how close to liquidation a user is. If the ratio goes under 1, the user is liquidated
    function _healthFactor(address _user) private view returns (uint256) {
        (
            uint256 totalBDCMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInfo(_user);
        uint256 collateral = (collateralValueInUsd * LIQUIDATION_THRESHOLD) /
            LIQUIDATION_PRECISION;
        return ((collateral * PRECISION) / totalBDCMinted);
    }

    //@param :_user is the person who wants to mint BDC. The function assert check whether _user has enough collateral
    //@notice the health factor is calculated based on aave docs
    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR)
            revert BDCEngine__BreaksHealthFactor(userHealthFactor);
    }
}
