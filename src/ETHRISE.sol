// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.7;
pragma experimental ABIEncoderV2;

/*
        __    __           __
.-----.|  |_ |  |--..----.|__|.-----..-----.
|  -__||   _||     ||   _||  ||__ --||  -__|
|_____||____||__|__||__|  |__||_____||_____|

ETH 2x Leveraged Token Market
Built on top of Yearn & Uniswap

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http:www.gnu.org/licenses/>.

I wrote this for ETHOnline Hackathon 2021. Enjoy.

(c) bayu <https://github.com/pyk> 2021

*/

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {rToken} from "./rToken.sol";

/**
 * @title ETHRISE
 * @notice ETH 2x leveraged token market built on top of Yearn & Uniswap.
 */
contract ETHRISE is ERC20 {
    /// @notice USDC token contract
    IERC20 public immutable USDC;

    /// @notice rETHRISE represents balance of the lender supplied to the market
    rToken public immutable rETHRISE;

    /// @notice Track how much supply is borrowed
    uint256 public totalUSDCBorrowed;

    /// @notice Event emitted when lender add supply to the market
    event SupplyAdded(address indexed by, uint256 amount);
    event SupplyRemoved();
    event LeveragedTokenMinted();
    event LeveragedTokenBurned();

    /**
     * @notice Contruct ETHRISE market
     */
    constructor() ERC20("ETH 2x Leverage Risedle", "ETHRISE") {
        // USDC Contract
        USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

        // Create new rETHRISE
        rETHRISE = new rToken(
            "Risedle ETHRISE Supply Shares",
            "rETHRISE",
            6, // Same as USDC decimals
            address(this) // Only this contract can mint & burn the token
        );

        // Set USDCBorrowed to zero
        totalUSDCBorrowed = 0;
    }

    /**
     * @notice getrETHRISEValueInUSDC retuns the value of rETHRISE in USDC
     * @dev Underlying math can be accesed here: https://hackmd.io/@bayualsyah/Sk3SOoVQF
     */
    function getrETHRISEValueInUSDC() internal view returns (uint256) {
        uint256 rETHRISETotalSupply = rETHRISE.totalSupply();
        // If total supply is 0, then return 1:1 USDC
        uint256 valueInUSDC = 1;
        // Otherwise calculate the value per rETHRISE
        if (rETHRISETotalSupply != 0) {
            uint256 totalUSDCManaged = USDC.balanceOf(address(this)) +
                totalUSDCBorrowed;
            valueInUSDC = totalUSDCManaged / rETHRISETotalSupply;
        }
        return valueInUSDC;
    }

    /**
     * @notice depositUSDC deposits USDC to the lending pool.
     * Lender will receive rToken represents their share to the pool
     */
    function depositUSDC(uint256 usdcAmount) external {
        // Transfer USDC to the contract
        USDC.transferFrom(msg.sender, address(this), usdcAmount);

        // Calculate rETHRISE minted amount
        uint256 mintedAmount = usdcAmount / getrETHRISEValueInUSDC();

        // Mint rETHRISE to the lender
        rETHRISE.mint(msg.sender, mintedAmount);
    }
}
