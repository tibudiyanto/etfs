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
    /// @notice hevm utils to alter mainnet state
    HEVM hevm;

    function setUp() public {
        hevm = new HEVM();
    }

    /// @notice Make sure all important variables are correctly set after deployment
    function test_VaultProperties() public {
        // Make sure underlying asset is correct
        assertEq(underlying, usdtAddress);

        // Make sure admin address is correct
        assertEq(admin, rvUSDTAdmin);

        // Make sure total borrowed is zero
        assertEq(totalBorrowed, 0);

        // Make sure total collected fees is zero
        assertEq(totalCollectedFees, 0);

        // Make sure optimal utilization rate is set to 90%
        assertEq(OPTIMAL_UTILIZATION_RATE_IN_ETHER, 900000000000000000);

        // Make sure the interest rate slop 1 is set to 20%
        assertEq(INTEREST_SLOPE_1_IN_ETHER, 200000000000000000);

        // Make sure the interest rate slop 2 is set to 60%
        assertEq(INTEREST_SLOPE_2_IN_ETHER, 600000000000000000);

        // Make sure the seconds per year is set
        assertEq(TOTAL_SECONDS_IN_A_YEAR, 31536000);

        // Make sure max borrow rate is set
        assertEq(MAX_BORROW_RATE_PER_SECOND_IN_ETHER, 50735667174); // Approx 393% APY

        // Make sure one wad correctly set
        assertEq(ONE_WAD, 1e18);

        // Make sure the Vault's token properties is correct
        IERC20Metadata vaultTokenMetadata = IERC20Metadata(address(this));
        assertEq(vaultTokenMetadata.name(), vaultTokenName);
        assertEq(vaultTokenMetadata.symbol(), vaultTokenSymbol);
        assertEq(vaultTokenMetadata.decimals(), 6); // Equal to USDT decimals

        // Make sure the total supply is set to zero
        assertEq(getVaultTokenTotalSupply(), 0);
    }

    /// @notice Make sure getTotalAvailableCash return correctly
    function test_GetTotalAvailableCash() public {
        uint256 amount;
        uint256 totalAvailable;

        amount = 1000 * 1e6; // 1000 USDT
        hevm.setUSDTBalance(address(this), amount);
        totalAvailable = getTotalAvailableCash();
        assertEq(totalAvailable, amount);

        amount = 200 * 1e6; // 200 USDT
        totalCollectedFees = 100 * 1e6; // 100 USDT
        hevm.setUSDTBalance(address(this), amount);
        totalAvailable = getTotalAvailableCash();
        assertEq(totalAvailable, amount - totalCollectedFees);

        // This most likely never happen; but we need to make sure to handle it
        // totalCollectedFees > Underlying balance
        amount = 100 * 1e6; // 100 USDT
        totalCollectedFees = 105 * 1e6; // 105 USDT
        hevm.setUSDTBalance(address(this), amount);
        totalAvailable = getTotalAvailableCash();
        assertEq(totalAvailable, 0);

        // Test with very high number
        amount = 100 * 1e12 * 1e6; // 100 trillion USDT
        totalCollectedFees = 90 * 1e12 * 1e6; // 90 trillion USDT
        hevm.setUSDTBalance(address(this), amount);
        totalAvailable = getTotalAvailableCash();
        assertEq(totalAvailable, 10 * 1e12 * 1e6); // 10 trillion USDT
    }

    /// @notice Make sure the Utilization Rate calculation is correct
    function test_GetUtilizationRateInEther() public {
        uint256 utilizationRateInEther;

        // Available=0 ; Borrowed=0
        utilizationRateInEther = getUtilizationRateInEther(0, 0);
        assertEq(utilizationRateInEther, 0);

        // Available=100 USDT; Borrowed=0
        utilizationRateInEther = getUtilizationRateInEther(100 * 1e6, 0);
        assertEq(utilizationRateInEther, 0);

        // Available=100 USDT; Borrowed=50 USDT
        utilizationRateInEther = getUtilizationRateInEther(
            100 * 1e6, // 100 USDT
            50 * 1e6 // 50 USDT
        );
        assertEq(utilizationRateInEther, 333333333333333333); // 0.33 Utilization rate

        // Available=50 USDT; Borrowed=100 USDT
        utilizationRateInEther = getUtilizationRateInEther(
            50 * 1e6, // 50 USDT
            100 * 1e6 // 100 USDT
        );
        assertEq(utilizationRateInEther, 666666666666666666); // 0.66 Utilization rate

        // Available=0; Borrowed=100 USDT
        utilizationRateInEther = getUtilizationRateInEther(0, 100 * 1e6);
        assertEq(utilizationRateInEther, 1 ether);

        // Test with very large number
        utilizationRateInEther = getUtilizationRateInEther(
            100 * 1e12 * 1e6, // 100 trillion USDT
            100 * 1e12 * 1e6 // 100 trillion USDT
        );
        assertEq(utilizationRateInEther, 0.5 ether);
    }

    /// @notice Make sure the borrow rate calculation is correct
    function test_GetBorrowRatePerSecondInEther() public {
        // Set the model parameters
        OPTIMAL_UTILIZATION_RATE_IN_ETHER = 0.9 ether; // 90% utilization
        INTEREST_SLOPE_1_IN_ETHER = 0.2 ether; // 20% slope 1
        INTEREST_SLOPE_2_IN_ETHER = 0.6 ether; // 60% slope 2
        uint256 borrowRatePerSecondInEther;

        // Initial state: 0 utilization
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(0);
        assertEq(borrowRatePerSecondInEther, 0);

        // 0.5 utilization rate (50%)
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(0.5 ether);
        assertEq(borrowRatePerSecondInEther, 3523310220); // approx 11.75% APY

        // 0.94 utilization rate (94%)
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(0.94 ether);
        assertEq(borrowRatePerSecondInEther, 19025875190); // approx 82.122% APY

        // 0.97 utilization rate (97%)
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(0.97 ether);
        assertEq(
            borrowRatePerSecondInEther,
            MAX_BORROW_RATE_PER_SECOND_IN_ETHER
        ); // approx 393% APY

        // 0.99 utilization rate (99%)
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(0.99 ether);
        assertEq(
            borrowRatePerSecondInEther,
            MAX_BORROW_RATE_PER_SECOND_IN_ETHER
        ); // approx 393% APY

        // 1.0 utilization rate (100%)
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(1 ether); // 100%
        assertEq(
            borrowRatePerSecondInEther,
            MAX_BORROW_RATE_PER_SECOND_IN_ETHER
        ); // approx 393% APY

        // More than 100% utilization rate should be capped to max borrow rate
        borrowRatePerSecondInEther = getBorrowRatePerSecondInEther(1.5 ether); // 150%
        assertEq(
            borrowRatePerSecondInEther,
            MAX_BORROW_RATE_PER_SECOND_IN_ETHER
        ); // approx 393% APY
    }

    /// @notice Make sure getInterestAmount is correct
    function test_GetInterestAmount() public {
        uint256 interestAmount;

        // Total Borrowed: 0
        // Borrow Rate Per Seconds: 0
        // Elapsed Seconds: 0
        // Expected interest amount: 0
        interestAmount = getInterestAmount(0, 0, 0);
        assertEq(interestAmount, 0);

        // Total Borrowed: x
        // Borrow Rate Per Seconds: 0
        // Elapsed Seconds: 0
        // Expected interest amount: 0
        interestAmount = getInterestAmount(
            100 * 1e6, // 100 USDT
            0,
            0
        );
        assertEq(interestAmount, 0);

        // Total Borrowed: 0
        // Borrow Rate Per Seconds: 0
        // Elapsed Seconds: y
        // Expected interest amount: 0
        interestAmount = getInterestAmount(0, 0, 20);
        assertEq(interestAmount, 0);

        // Total Borrowed: x
        // Borrow Rate Per Seconds: y
        // Elapsed Seconds: z
        // Expected interest amount: 0
        interestAmount = getInterestAmount(
            100 * 1e6, // 100 USDT
            3523310220, // Approx 11.75% APY
            86400 // 86400 seconds ~ 24 hours
        );
        assertEq(interestAmount, 30441); // in 1e6 precision or 0.0304414003 USDT

        // Test with very large numbers
        interestAmount = getInterestAmount(
            100 * 1e12 * 1e6, // 100 trillion USDT
            3523310220, // Approx 11.75% APY
            60 * 60 * 24 * 7 // Approx 7 weeks
        );
        assertEq(interestAmount, 213089802105600000); // in 1e6 precision or 213B USDT
    }

    /// @notice Make sure updateVaultStates update the vault states correctly
    function test_UpdateVaultStates() public {
        // interestAmount=0
        totalBorrowed = 100 * 1e6; // 100 USDT
        totalCollectedFees = 5 * 1e6; // 5 USDT
        updateVaultStates(0);
        assertEq(totalBorrowed, 100 * 1e6);
        assertEq(totalCollectedFees, 5 * 1e6);

        // interestAmount=10 USDT
        totalBorrowed = 100 * 1e6; // 100 USDT
        totalCollectedFees = 5 * 1e6; // 5 USDT
        updateVaultStates(10 * 1e6); // 10 USDT
        // The totalBorrowed & totalCollectedFees should be updated
        assertEq(totalBorrowed, 109000000); // 109 USDT
        assertEq(totalCollectedFees, 6000000); // 6 USDT

        // Test with very large numbers
        totalBorrowed = 100 * 1e12 * 1e6; // 100 trillion USDT
        totalCollectedFees = 1 * 1e12 * 1e6; // 1 trillion USDT
        updateVaultStates(10 * 1e12 * 1e6); // 10 trillion USDT
        assertEq(totalBorrowed, 109 * 1e12 * 1e6); // 109 trillion USDT
        assertEq(totalCollectedFees, 2 * 1e12 * 1e6); // 2 trillion USDT
    }

    /// @notice Make sure accrue interest is working perfectly
    function test_AccrueInterest() public {
        bool invalid;

        // Scenario 1: 0% utilization
        totalBorrowed = 0;
        totalCollectedFees = 0;
        uint256 contractBalance = 1000 * 1e6; // 1000 USDT
        hevm.setUSDTBalance(address(this), contractBalance); // Set the contract balance
        invalid = accrueInterest();
        assertFalse(invalid);
        // Make sure it doesn't change the totalBorrowed and totalCollectedFees
        assertEq(totalBorrowed, 0);
        assertEq(totalCollectedFees, 0);

        // Scenario 2: Below optimal utilization rate
        totalBorrowed = 100 * 1e6; // 100 USDT
        totalCollectedFees = 20 * 1e6; // 20 USDT
        hevm.setUSDTBalance(address(this), 50 * 1e6); // Set contract balance
        lastTimestampInterestAccrued = block.timestamp; // Set accured interest to now
        // Set block timestamp to 24 hours later
        hevm.warp(lastTimestampInterestAccrued + (60 * 60 * 24));
        // Perform interest calculation
        invalid = accrueInterest();
        assertFalse(invalid);
        // Make sure the totalBorrowed and totalCollectedFees are updated
        assertEq(totalBorrowed, 100042149); // 100 + (90% of interest amount)
        assertEq(totalCollectedFees, 20004683); // 20 + (10% of interest amount)

        // Scenario 3: Above optimzal utilization rate
        totalBorrowed = 400 * 1e6; // 400 USDT
        totalCollectedFees = 20 * 1e6; // 20 USDT
        hevm.setUSDTBalance(address(this), 50 * 1e6); // Set contract balance
        lastTimestampInterestAccrued = block.timestamp; // Set accured interest to now
        // Set block timestamp to 3 hours later
        hevm.warp(lastTimestampInterestAccrued + (60 * 60 * 3));
        // Perform interest calculation
        invalid = accrueInterest();
        assertFalse(invalid);
        // Make sure the totalBorrowed and totalCollectedFees are updated
        assertEq(totalBorrowed, 400056712); // 400 + (90% of interest amount)
        assertEq(totalCollectedFees, 20006301); // 20 + (10% of interest amount)

        // Scenario 4: Maximum utilization rate
        totalBorrowed = 15000 * 1e6; // 15000 USDT
        totalCollectedFees = 20 * 1e6; // 20 USDT
        hevm.setUSDTBalance(address(this), 50 * 1e6); // Set contract balance
        lastTimestampInterestAccrued = block.timestamp; // Set accured interest to now
        // Set block timestamp to 10 hours later
        hevm.warp(lastTimestampInterestAccrued + (60 * 60 * 10));
        // Perform interest calculation
        invalid = accrueInterest();
        assertFalse(invalid);
        // Make sure the totalBorrowed and totalCollectedFees are updated
        assertEq(totalBorrowed, 15024657534); // 400 + (90% of interest amount)
        assertEq(totalCollectedFees, 22739726); // 20 + (10% of interest amount)
    }

    /// @notice Make sure the getExchangeRateWad() working perfectly
    function test_GetExchangeRateWad() public {
        uint256 exchangeRateWad;

        // Scenario 1: Initial exchange rate
        // totalSupply = 0
        // exchangeRate should be 1:1
        exchangeRateWad = getExchangeRateWad();
        assertEq(exchangeRateWad, ONE_WAD);

        // Scenario 2: Simulate lender already supply some asset but the
        // interest is not accrued yet
        uint256 suppliedUSDT = 100 * 1e6; // 100 USDT
        hevm.setUSDTBalance(address(this), suppliedUSDT); // Set contract balance to 100USDT

        totalBorrowed = 0;
        totalCollectedFees = 0;

        // Mint to random address with 1:1 exchange rate
        address supplier = hevm.addr(1);
        _mint(supplier, 100 * 1e6); // Even though the decimals of rvToken is 8

        // Make sure the exchange rate is correct
        exchangeRateWad = getExchangeRateWad();
        assertEq(exchangeRateWad, ONE_WAD);

        // Scenario 3: Simulate that the totalBorrowed is 50 USDT and interest
        // already accrued 10 USDT.
        // 1. Someone borrow the asset 50 USDT
        hevm.setUSDTBalance(address(this), suppliedUSDT - (50 * 1e6)); // Set contract balance to 50USDT previously 100USDT
        totalBorrowed = (50 * 1e6);

        // 2. Interest accrued 10 USDT
        totalBorrowed = totalBorrowed + (9 * 1e6); // 9 USDT (90% of interest accrued)
        totalCollectedFees = 1 * 1e6; // 1 USDT (10% of interest accrued)

        // 3. Exchange rate should ~1.08
        exchangeRateWad = getExchangeRateWad();
        assertEq(exchangeRateWad, 1080000000000000000); // 1.08
    }
}
