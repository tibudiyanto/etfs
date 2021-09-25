// SPDX-License-Identifier: GPL-3.0-or-later

// Risedle's Vault Internal Test
// Test & validate all internal functionalities

pragma solidity ^0.8.7;
pragma experimental ABIEncoderV2;

import "lib/ds-test/src/test.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {HEVM} from "./utils/HEVM.sol";
import {RisedleVault} from "../RisedleVault.sol";

// Set Risedle's Vault properties
string constant vaultTokenName = "Risedle USDT Vault";
string constant vaultTokenSymbol = "rvUSDT";
address constant usdtAddress = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant rvUSDTAdmin = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // set random admin

contract RisedleVaultInternalTest is
    DSTest,
    RisedleVault(vaultTokenName, vaultTokenSymbol, usdtAddress, rvUSDTAdmin)
{
    /// @notice Make sure all important variables are correctly set after deployment
    function test_VaultProperties() public {
        // Make sure underlying asset is correct
        assertEq(underlying, usdtAddress);

        // Make sure admin address is correct
        assertEq(admin, rvUSDTAdmin);

        // Make sure total borrowed is zero
        assertEq(totalBorrowed, 0);

        // Make sure total reserved is zero
        assertEq(totalReserved, 0);

        // Make sure optimal utilization rate is set to 90%
        assertEq(OPTIMAL_UTILIZATION_RATE_WAD, 900000000000000000);

        // Make sure the interest rate slop 1 is set to 20%
        assertEq(INTEREST_SLOPE_1_WAD, 200000000000000000);

        // Make sure the interest rate slop 2 is set to 60%
        assertEq(INTEREST_SLOPE_2_WAD, 600000000000000000);

        // Make sure the seconds per year is set
        assertEq(SECONDS_PER_YEAR_WAD, 31536000000000000000000000);

        // Make sure max borrow rate is set
        assertEq(MAX_BORROW_RATE_PER_SECOND_WAD, 50735667174); // Approx 393% APY

        // Make sure one wad correctly set
        assertEq(ONE_WAD, 1e18);

        // Make sure the Vault's token properties is correct
        IERC20Metadata vaultTokenMetadata = IERC20Metadata(address(this));
        assertEq(vaultTokenMetadata.name(), vaultTokenName);
        assertEq(vaultTokenMetadata.symbol(), vaultTokenSymbol);
        assertEq(vaultTokenMetadata.decimals(), 8);
    }

    /// @notice Make sure the Utilization Rate calculation is correct
    function test_GetUtilizationRate() public {
        bool invalid;
        uint256 utilizationRateWad;

        // Initial state: zero available, zero borrowed and zero reserved
        (invalid, utilizationRateWad) = getUtilizationRateWad(0, 0, 0);
        assertFalse(invalid);
        assertEq(utilizationRateWad, 0);

        // x available, zero borrowed, zero reserved
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            100 * 1e6, // 100USDT
            0,
            0
        );
        assertFalse(invalid);
        assertEq(utilizationRateWad, 0);

        // x available, y borrowed, zero reserved
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            100 * 1e6, // 100USDT
            50 * 1e6, // 50 USDT
            0
        );
        assertFalse(invalid);
        assertEq(utilizationRateWad, 333333333333333333); // 0.33 Utilization rate

        // x available, y borrowed, z reserved
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            100 * 1e6, // 100USDT
            50 * 1e6, // 50 USDT
            10 * 1e6 // 10 USDT reserved
        );
        assertFalse(invalid);
        assertEq(utilizationRateWad, 357142857142857143); // 0.35 Utilization rate

        // x available < y borrowed, zero reserved
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            50 * 1e6, // 50USDT
            100 * 1e6, // 50 USDT
            0
        );
        assertFalse(invalid);
        assertEq(utilizationRateWad, 666666666666666667); // 0.71 Utilization rate

        // More than 100% utilization rate
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            0,
            100 * 1e6, // 100 USDT
            10 * 1e6 // 10 USDT
        );
        assertFalse(invalid);
        assertEq(utilizationRateWad, ONE_WAD);

        // Reserved amount should not be too large
        // x available < y borrowed < z reserved
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            50 * 1e6, // 50USDT
            100 * 1e6, // 50 USDT
            200 * 1e6 // 200 USDT
        );
        assertTrue(invalid);

        // Test overflow
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            ((2**256) - 1),
            ((2**256) - 1),
            0
        );
        assertTrue(invalid);
    }

    /// @notice Make sure the borrow rate calculation is correct
    function test_GetBorrowRate() public {
        // Set the model parameters
        OPTIMAL_UTILIZATION_RATE_WAD = 900000000000000000; // 90% utilization
        INTEREST_SLOPE_1_WAD = 200000000000000000; // 20% slope 1
        INTEREST_SLOPE_2_WAD = 600000000000000000; // 60% slope 2

        // Set utilization rate
        uint256 utilizationRateWad1 = 500000000000000000; // 0.5 or 50%
        uint256 expectedBorrowRatePerSecondWad1 = 3523310220; // approx 11.75% APY

        // Calculate borrow rate per second
        uint256 borrowRatePerSecondWad1 = getBorrowRatePerSecondWad(
            utilizationRateWad1
        );
        assertEq(borrowRatePerSecondWad1, expectedBorrowRatePerSecondWad1);

        // Set utilization rate
        uint256 utilizationRateWad2 = 940000000000000000; // 0.94 or 94%
        uint256 expectedBorrowRatePerSecondWad2 = 19025875190; // approx 82.122% APY

        // Calculate borrow rate per second
        uint256 borrowRatePerSecondWad2 = getBorrowRatePerSecondWad(
            utilizationRateWad2
        );
        assertEq(borrowRatePerSecondWad2, expectedBorrowRatePerSecondWad2);

        // Make sure capped borrow rate works
        uint256 utilizationRateWad3 = 970000000000000000; // 97%
        uint256 borrowRatePerSecondWad3 = getBorrowRatePerSecondWad(
            utilizationRateWad3
        );
        assertEq(borrowRatePerSecondWad3, MAX_BORROW_RATE_PER_SECOND_WAD);
    }
}
