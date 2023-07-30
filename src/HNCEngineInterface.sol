// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface HNCEngineInterface {
    function depositCollater() external;

    function mintBDC() external;

    function depositCollateralAndMintBDC() external;

    function redeemCollateral() external;

    function redeemCollateralForBDC() external;

    function burnBDC() external;

    function liquidate() external;

    function getHealthFactor() external view;
}
