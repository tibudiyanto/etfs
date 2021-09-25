// SPDX-License-Identifier: GPL-3.0-or-later

// Risedle's Vault Contract
// The money market protocol that powers Risedle ETFs.
//
// The interest rate model is available here: https://observablehq.com/@pyk/ethrise
// It uses wad, a decimal number with 18 digits of precision, to represent the
// interest rate.
//
// I wrote this for ETHOnline Hackathon 2021. Enjoy.

// Copyright (c) 2021 Bayu - All rights reserved
// github: pyk

pragma solidity ^0.8.7;
pragma experimental ABIEncoderV2;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {DSMath} from "lib/meth/src/math.sol";

/// @title Risedle's Vault
contract RisedleVault is ERC20, AccessControl, DSMath {
    using SafeERC20 for IERC20;

    /// @notice Only valid borrower can borrow and repay underlying assets
    bytes32 public constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    /// @notice The underlying assets address contract (ERC20)
    address public immutable underlying;

    /// @notice The vault's admin address
    address public admin;

    /// @notice The total amount of borrowed assets in the vault
    uint256 public totalBorrowed;

    /// @notice The total amount of collected fees in the vault
    uint256 public totalCollectedFees;

    /// @notice Optimal utilization rate stored in wad
    ///         For example, 90% or 0.9 is equal to
    uint256 public OPTIMAL_UTILIZATION_RATE_WAD;

    /// @notice Interest slope 1, stored in wad
    uint256 public INTEREST_SLOPE_1_WAD;

    /// @notice Interest slop 2, stored in wad
    uint256 public INTEREST_SLOPE_2_WAD;

    /// @notice Number of seconds in a year, stored in wad
    uint256 public immutable SECONDS_PER_YEAR_WAD = 31536000000000000000000000;

    /// @notice 1.0 stored as wad, 1e18 precision
    uint256 public immutable ONE_WAD = 1000000000000000000;

    /// @notice Maximum borrow rate per second
    uint256 public immutable MAX_BORROW_RATE_PER_SECOND_WAD = 50735667174; // Approx 393% APY

    /// @notice Performance fee for the lender
    uint256 public PERFORMANCE_FEE_WAD = 100000000000000000; // 10% performance fee

    /// @notice Timestammp that interest was last accrued at
    uint256 public lastTimestampInterestAccrued;

    /// @notice Event emitted when the utulization rate is invalid
    event UtiliationRateInvalid(
        uint256 cash,
        uint256 borrowed,
        uint256 reserved,
        uint256 rate
    );

    /// @notice Event emitted when the borrow rate is invalid
    event BorrowRatePerSecondInvalid(uint256 utilizationRateWad);

    /// @notice Event emitted then failed to calculate the timestamp delta
    event TimestampDeltaInvalid(uint256 previous, uint256 current);

    /**
     * @notice Contruct new vault
     * @param name The vault's token name
     * @param symbol The vault's token symbol
     * @param underlying_ The ERC20 contract address of underlying asset
     * @param admin_ The vault's admin address
     */
    constructor(
        string memory name,
        string memory symbol,
        address underlying_,
        address admin_
    ) ERC20(name, symbol) {
        // Sanity check
        IERC20(underlying_).totalSupply();

        // Set underlying asset contract address
        underlying = underlying_;

        // Setup admin role
        admin = admin_;
        _setupRole(DEFAULT_ADMIN_ROLE, admin_);

        // Set initial interest rate model parameters
        // See visualization here: https://observablehq.com/@pyk/ethrise
        OPTIMAL_UTILIZATION_RATE_WAD = 900000000000000000; // 90% utilization
        INTEREST_SLOPE_1_WAD = 200000000000000000; // 20% slope 1
        INTEREST_SLOPE_2_WAD = 600000000000000000; // 60% slope 2
    }

    /**
     * @notice Similar to cToken decimals
     * @dev https://docs.openzeppelin.com/contracts/4.x/erc20#a-note-on-decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return 8;
    }

    /**
     * @notice grantAsBorrower grants account access to borrow the underlying asset of RisedleUSD
     * @dev Only admin can call this function
     * @param account The contract address granted access to borrow
     */
    function grantAsBorrower(address account)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setupRole(BORROWER_ROLE, account);
    }

    /**
     * @notice isBorrower returns true if account is borrower
     * @param account The contract address
     */
    function isBorrower(address account) public view returns (bool) {
        return hasRole(BORROWER_ROLE, account);
    }

    /**
     * @notice getTotalAvailable returns the total amount of underlying asset
     *         that available to borrow
     * @return The amount of underlying asset ready to borrow
     */
    function getTotalAvailable() internal view returns (uint256) {
        IERC20 underlyingToken = IERC20(underlying);
        uint256 underlyingBalance = underlyingToken.balanceOf(address(this));
        if (totalCollectedFees >= underlyingBalance) return 0;
        return underlyingBalance - totalCollectedFees;
    }

    /**
     * @notice getUtilizationRateWad calculates the utilization rate of
     *         the vault. If there is an overflow or underflow, simply
     *         return 0 with invalid=true.
     * @param available The amount of cash available to borrow in the vault
     * @param borrowed The amount of borrowed asset in the vault
     * @return invalid True if overflow/underflow and reserved amount too large
     * @return rateWad The utilization rate as wad, valid if invalid=false
     */
    function getUtilizationRateWad(uint256 available, uint256 borrowed)
        internal
        pure
        returns (bool invalid, uint256 rateWad)
    {
        // Utilization rate is 0% when there is no borrowed asset
        if (borrowed == 0) {
            return (false, 0);
        }
        // Utilization rate is 100% when there is no cash available
        if (available == 0 && borrowed > 0) {
            return (false, ONE_WAD);
        }

        // utilization rate = amount borrowed / (amount available + amount borrowed)
        // Perform safe arithmetic with overflow/underflow flagging
        uint256 totalAmount;
        (invalid, totalAmount) = madd(available, borrowed);
        if (invalid) return (invalid, 0);
        (invalid, rateWad) = mwdiv(borrowed, totalAmount);
        if (invalid) return (invalid, 0);
        // Capped rateWad
        rateWad = min(rateWad, ONE_WAD);
    }

    /**
     * @notice getBorrowRatePerSecondWad calculates the borrow rate per second.
     * @param utilizationRateWad The current utilization rate, stored as wad
     * @return invalid True if overflow/underflow and reserved amount too large
     * @return borrowRatePerSecondWad Borrow rate per second as Wad
     */
    function getBorrowRatePerSecondWad(uint256 utilizationRateWad)
        internal
        view
        returns (bool invalid, uint256 borrowRatePerSecondWad)
    {
        // utilizationRateWad should in range [0, 1e18], Otherwise return max borrow rate
        if (utilizationRateWad >= ONE_WAD)
            return (false, MAX_BORROW_RATE_PER_SECOND_WAD);

        // Calculate the borrow rate
        // See the formula here: https://observablehq.com/@pyk/ethrise
        if (utilizationRateWad <= OPTIMAL_UTILIZATION_RATE_WAD) {
            uint256 z; // temporary variable
            (invalid, z) = mwdiv(
                utilizationRateWad,
                OPTIMAL_UTILIZATION_RATE_WAD
            );
            if (invalid) return (invalid, z);
            (invalid, z) = mwmul(z, INTEREST_SLOPE_1_WAD); // Borrow rate per year
            if (invalid) return (invalid, z);
            (invalid, borrowRatePerSecondWad) = mwdiv(z, SECONDS_PER_YEAR_WAD);
            return (invalid, borrowRatePerSecondWad);
        } else {
            // temporary variables
            uint256 x;
            uint256 y;
            uint256 z;

            (invalid, x) = msub(
                utilizationRateWad,
                OPTIMAL_UTILIZATION_RATE_WAD
            );
            if (invalid) return (invalid, x);
            (invalid, y) = msub(ONE_WAD, utilizationRateWad);
            if (invalid) return (invalid, y);
            (invalid, z) = mwdiv(x, y);
            if (invalid) return (invalid, z);
            (invalid, z) = mwmul(z, INTEREST_SLOPE_2_WAD);
            if (invalid) return (invalid, z);
            (invalid, z) = madd(INTEREST_SLOPE_1_WAD, z); // Borrow rate per year
            if (invalid) return (invalid, z);
            (invalid, borrowRatePerSecondWad) = mwdiv(z, SECONDS_PER_YEAR_WAD);
            if (invalid) return (invalid, borrowRatePerSecondWad);
            // Make sure the borrow rate is not absurdly high
            uint256 cappedBorrowRatePerSecondWad = min(
                borrowRatePerSecondWad,
                MAX_BORROW_RATE_PER_SECOND_WAD
            );
            return (false, cappedBorrowRatePerSecondWad);
        }
    }

    /**
     * @notice getInterestAmount calculate amount of interest based on the total
     *         borrowed and borrow rate per second.
     * @param borrowedAmount Total of borrowed amount, in underlying decimals
     * @param borrowRatePerSecondWad Borrow rates per second, stored as wad number
     * @param elapsedSeconds Number of seconds elapsed since last collection
     * @return invalid True if there is an overflow
     * @return amount The total interest amount, it have similar decimals with
     *         totalBorrowed and totalCollectedFees. If invalid=true, amount is
     *         set to zero.
     */
    function getInterestAmount(
        uint256 borrowedAmount,
        uint256 borrowRatePerSecondWad,
        uint256 elapsedSeconds
    ) internal pure returns (bool invalid, uint256 amount) {
        // Early returns
        if (
            borrowedAmount == 0 ||
            borrowRatePerSecondWad == 0 ||
            elapsedSeconds == 0
        ) {
            return (false, 0);
        }

        // Calculate the amount of interest
        // interest amount = borrowRatePerSecondWad * elapsedSeconds * borrowedAmount
        uint256 z; // temporary variable
        (invalid, z) = mmul(borrowRatePerSecondWad, elapsedSeconds); // output wad; 1e18 precision
        if (invalid) return (invalid, 0);
        (invalid, z) = mmul(z, borrowedAmount); // output wad; 1e18 precision
        if (invalid) return (invalid, 0);
        amount = z / ONE_WAD; // Convert to underlying precision/decimals
    }

    /**
     * @notice updateVaultStates update the totalBorrowed and totalCollectedFees
     * @param interestAmount The total of interest amount to be splitted, the decimals
     *        is similar to the underlying asset.
     * @return invalid True if there is an overflow
     */
    function updateVaultStates(uint256 interestAmount)
        internal
        returns (bool invalid)
    {
        // Get the fee
        uint256 z;
        (invalid, z) = mmul(PERFORMANCE_FEE_WAD, interestAmount); // In 1e18 precision
        if (invalid) return invalid;
        uint256 feeAmount = z / ONE_WAD; // Convert to underlying precision

        // Get the borrow interest
        uint256 borrowInterestAmount;
        (invalid, borrowInterestAmount) = msub(interestAmount, feeAmount);
        if (invalid) return invalid;

        // Update the states
        (invalid, totalBorrowed) = madd(totalBorrowed, borrowInterestAmount);
        if (invalid) return invalid;
        (invalid, totalCollectedFees) = madd(totalCollectedFees, feeAmount);
        if (invalid) return invalid;

        // Set invalid as false
        return false;
    }

    /**
     * @notice accrueInterest accrues interest to totalBorrowed and totalCollectedFees
     * @dev This calculates interest accrued from the last checkpointed timestamp
     *      up to the current timestamp and writes new checkpoint to storage.
     */
    function accrueInterest() public returns (bool invalid) {
        // Get the current timestamp, get last timestamp accrued and set the last time accrued
        uint256 currentTimestamp = block.timestamp;
        uint256 previousTimestamp = lastTimestampInterestAccrued;
        lastTimestampInterestAccrued = currentTimestamp;

        // If currentTimestamp and previousTimestamp is similar then return early
        if (currentTimestamp == previousTimestamp) return false;

        // Get total amount available to borrow
        uint256 totalAvailable = getTotalAvailable();

        // Get current utilization rate
        uint256 utilizationRateWad;
        (invalid, utilizationRateWad) = getUtilizationRateWad(
            totalAvailable,
            totalBorrowed
        );
        if (invalid) return invalid;

        // Get borrow rate per second
        uint256 borrowRatePerSecondWad;
        (invalid, borrowRatePerSecondWad) = getBorrowRatePerSecondWad(
            utilizationRateWad
        );
        if (invalid) return invalid;

        // Get time elapsed since last accrued
        uint256 elapsedSeconds;
        (invalid, elapsedSeconds) = msub(currentTimestamp, previousTimestamp);
        if (invalid) return invalid;

        // Get the interest amount
        uint256 interestAmount;
        (invalid, interestAmount) = getInterestAmount(
            totalBorrowed,
            borrowRatePerSecondWad,
            elapsedSeconds
        );
        if (invalid) return invalid;

        // Update the vault states based on the interest amount:
        // totalBorrow & totalCollectedFees
        invalid = updateVaultStates(interestAmount);
        if (invalid) return invalid;

        // Set invalid as false
        return false;
    }
}
