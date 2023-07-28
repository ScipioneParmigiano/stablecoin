// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

//@author: Pietro Zanotta
//@title: Bardottocoin
//@description: The following contract creates an algoritmic stablecoin
//              collateralized by wETH and wBTC, whose price is anchored
//              to 1 USD.

contract Bardottocoin is ERC20Burnable, Ownable {
    error Bardottocoin__MustBeMoreThanZero();
    error Bardottocoin__BurnAmountExceedsBalance();
    error Bardottocoin__NotZeroAddress();

    constructor() ERC20("Bardottocoin", "BDC") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) revert Bardottocoin__MustBeMoreThanZero();
        if (_amount >= balance) revert Bardottocoin__BurnAmountExceedsBalance();

        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) revert Bardottocoin__NotZeroAddress();
        if (_amount <= 0) revert Bardottocoin__MustBeMoreThanZero();

        _mint(_to, _amount);
        return true;
    }
}
