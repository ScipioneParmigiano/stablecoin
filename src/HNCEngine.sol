// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Hinnycoin} from "src/Hinnycoin.sol";
import {HNCEngineInterface} from "src/HNCEngineInterface.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

//@author: Pietro Zanotta
//@title: HNCEngine
//@description: The following contract regulates the Hinnycoin stablecoin,
//              which is collateralized by wETH and wBTC and whose price is anchored
//              to 1 USD.

contract HNCEngine {
    /*
     *** Errors ***
     */
    error HNCEngine__MustBeMoreThanZero();
    error HNCEngine__TokenAddressesAndPriceFeedAddressesShouldHaveSameLength();
    error HNCEngine__TokenNotAllowedAsCollateral(address token);
    error HNCEngine__TransferFailed();
    error HNCEngine__BreaksHealthFactor(uint256 healthFactor);
    error HNCEngine__MintFailed();
    error HNCEngine__HealthFactorOk();
    error HNCEngine__HealthFactorNotImproved();
    /*
     *** Events ***
     */

    event CollateralDeposited(
        address indexed sender,
        address indexed token,
        uint256 indexed amout
    );
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed tokenCollateralAddress,
        uint256 amountCollateral
    );

    /*
     *** Variables ***
     */
    Hinnycoin private immutable i_hnc;
    mapping(address => address) private s_tokenToPriceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address => uint256) private s_HNCMinted;
    address[] private s_collateralTokens;
    uint256 constant LIQUIDATION_THRESHOLD = 50; // 200%
    uint256 constant LIQUIDATION_PRECISION = 100;
    uint256 constant LIQUIDATION_BONUS = 10;
    uint256 constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 constant MIN_HEALTH_FACTOR = 1e18;

    /*
     *** Modifiers ***
     */
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert HNCEngine__MustBeMoreThanZero();
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_tokenToPriceFeeds[tokenAddress] == address(0)) {
            revert HNCEngine__TokenNotAllowedAsCollateral(tokenAddress);
        }
        _;
    }

    /*
     *** Functions ***
     */

    constructor(
        address[] memory _tokenAddresses,
        address[] memory _priceFeedAddresses,
        address _hncAddress
    ) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert HNCEngine__TokenAddressesAndPriceFeedAddressesShouldHaveSameLength();
        }

        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_tokenToPriceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_hnc = Hinnycoin(_hncAddress);
    }

    //@param: tokenCollateralAddress is the address of the token to deposit as collateral (e.g. wETH)
    //@param: amountCollateral is the amount of collateral to deposit
    function depositCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    )
        public
        moreThanZero(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
    {
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
        if (!success) revert HNCEngine__TransferFailed();
    }

    //@param: amount of Hinnycoin to mint. It has to be overcollateralized
    function mintHNC(
        uint256 _amountHNCToMint
    ) public moreThanZero(_amountHNCToMint) {
        s_HNCMinted[msg.sender] += _amountHNCToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool mintSuccess = i_hnc.mint(msg.sender, _amountHNCToMint);
        if (!mintSuccess) revert HNCEngine__MintFailed();
    }

    //@param: _tokenCollateralAddress address of the token to use as collateral
    //@param: _amountCollateral the amount of that token
    //@param: _amountHNCToMint the amount of HNC to be minted
    function depositCollateralAndMintHNC(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountHNCToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintHNC(_amountHNCToMint);
    }

    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) external moreThanZero(amountCollateral) {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //@param: _tokenCollateral address of the token to use as collateral
    //@param: _amountCollateral the amount of that token
    //@param: _amountHNCToBurn the amount of HNC to be burned
    //@description: funtion to redeem collateral and burn associated HNC
    function redeemCollateralForHNC(
        address _tokenCollateral,
        uint256 _amountCollateral,
        uint256 _amountHCNToBurn
    ) external {
        _burnHNC(_amountHCNToBurn, msg.sender, msg.sender);
        _redeemCollateral(
            _tokenCollateral,
            _amountCollateral,
            msg.sender,
            msg.sender
        );
    }

    function burnHNC(uint256 _amount) public moreThanZero(_amount) {
        _burnHNC(_amount, msg.sender, msg.sender);
    }

    //@param: collateral the collateral address to liquidate from the user
    //@param: user the one who broke the health factor
    //@param: amount of HNC to burn to improve the user's health factor
    function liquidate(
        address _collateral,
        address _user,
        uint256 _debtToCover
    ) external moreThanZero(_debtToCover) {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor >= MIN_HEALTH_FACTOR) {
            revert HNCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            _collateral,
            _debtToCover
        );
        // give a 10% bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(
            _collateral,
            totalCollateralToRedeem,
            _user,
            msg.sender
        );
        _burnHNC(_debtToCover, _user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(_user);
        if (endingUserHealthFactor <= userHealthFactor)
            revert HNCEngine__HealthFactorNotImproved();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    //@description: function to get the price of tokens in USD
    function _tokenPriceToUsd(
        address _token,
        uint256 _amount
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeeds[_token]
        );

        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) /
            PRECISION;
    }

    function tokenPriceToUsd(
        address _token,
        uint256 _amount
    ) external view returns (uint256) {
        return _tokenPriceToUsd(_token, _amount);
    }

    function getTokenAmountFromUsd(
        address _token,
        uint256 _usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeeds[_token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return ((_usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION));
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

    function _redeemCollateral(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        address _from,
        address _to
    ) private moreThanZero(_amountCollateral) {
        s_collateralDeposited[_from][
            _tokenCollateralAddress
        ] -= _amountCollateral;

        emit CollateralRedeemed(
            _from,
            _to,
            _tokenCollateralAddress,
            _amountCollateral
        );

        bool success = IERC20(_tokenCollateralAddress).transfer(
            payable(_to),
            _amountCollateral
        );
        if (!success) revert HNCEngine__TransferFailed();

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //@description: returns the number of HNC minteb by the user and the value in usd of it's collateral
    function _getAccountInfo(
        address _user
    ) internal view returns (uint256, uint256) {
        uint256 collateralValueInUsd = getCollateralAccountValueInUsd(_user);
        uint256 hncMinted = s_HNCMinted[_user];
        return (hncMinted, collateralValueInUsd);
    }

    function getAccountInfo(
        address _user
    ) external view returns (uint256, uint256) {
        return _getAccountInfo(_user);
    }

    function _burnHNC(
        uint256 _amount,
        address _onBehalfOf,
        address _from
    ) internal {
        s_HNCMinted[_onBehalfOf] -= _amount;
        bool success = i_hnc.transferFrom(_from, address(this), _amount);
        if (!success) revert HNCEngine__TransferFailed();
        i_hnc.burn(_amount);
    }

    //@description: calculate how close to liquidation a user is. If the ratio goes under 1, the user is liquidated
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInfo(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalDscMinted;
    }

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    //@param :_user is the person who wants to mint HNC. The function assert check whether _user has enough collateral
    //@notice the health factor is calculated based on aave docs
    function _revertIfHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor <= MIN_HEALTH_FACTOR)
            revert HNCEngine__BreaksHealthFactor(userHealthFactor);
    }

    function healthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getUsdValue(
        uint256 amount,
        address token
    ) external view returns (uint256) {
        return _getUsdValue(amount, token);
    }

    function _getUsdValue(
        uint256 amount,
        address token
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();

        return
            (amount * uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION;
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
