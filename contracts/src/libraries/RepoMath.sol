// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RepoMath
/// @notice Pure math library for repo pricing and risk calculations
/// @dev    All functions are internal pure — no state, no external calls
///         Used by RepoVault, LendingPool, and MarginEngine

library RepoMath {

    // ─── Constants ───────────────────────────────────────────────
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant DAYS_IN_YEAR = 360;   // ACT/360 — standard money market convention

    // ─── Loan Sizing ─────────────────────────────────────────────

    /// @notice Maximum loan against collateral after applying haircut
    /// @param  collateralValue  Current market value of collateral (any unit)
    /// @param  haircutBps       Haircut in basis points (e.g. 500 = 5%)
    /// @return maxLoan          Maximum USDC that can be borrowed
    /// @dev    maxLoan = collateralValue × (1 - haircut%)
    ///         Example: collateral = $1000, haircut = 5%
    ///                  maxLoan = $1000 × 0.95 = $950
    function maxLoanAmount(
        uint256 collateralValue,
        uint256 haircutBps
    ) internal pure returns (uint256 maxLoan) {
        require(haircutBps < BASIS_POINTS, "Haircut must be < 100%");
        maxLoan = (collateralValue * (BASIS_POINTS - haircutBps)) / BASIS_POINTS;
    }

    // ─── Interest Calculation ────────────────────────────────────

    /// @notice Repo interest using ACT/360 day-count convention
    /// @param  principal    Loan principal in USDC (6 decimals)
    /// @param  repoRateBps  Annual repo rate in basis points (e.g. 550 = 5.5%)
    /// @param  termDays     Actual number of days repo is open
    /// @return interest     Interest owed in USDC
    /// @dev    Interest = P × r × (d / 360)
    ///         Example: $1000 principal, 5.5% rate, 7 days
    ///                  Interest = 1000 × 0.055 × (7/360) = $1.069
    ///         ACT/360 is the real-world money market convention used on
    ///         every repo desk globally (ICMA standard)
    function repoInterest(
        uint256 principal,
        uint256 repoRateBps,
        uint256 termDays
    ) internal pure returns (uint256 interest) {
        require(termDays > 0, "Term must be > 0 days");
        interest = (principal * repoRateBps * termDays) / (BASIS_POINTS * DAYS_IN_YEAR);
    }

    // ─── Risk Monitoring ─────────────────────────────────────────

    /// @notice Current Loan-to-Value ratio in basis points
    /// @param  loanAmount       Outstanding loan (USDC, 6 decimals)
    /// @param  collateralValue  Current collateral market value (same unit as loan)
    /// @return ltv              LTV in basis points (e.g. 9000 = 90%)
    /// @dev    LTV = (loan / collateral) × 10000
    ///         LTV of 10000 (100%) means fully underwater — liquidate immediately
    function currentLTV(
        uint256 loanAmount,
        uint256 collateralValue
    ) internal pure returns (uint256 ltv) {
        if (collateralValue == 0) return BASIS_POINTS; // 100% — treat as critical
        ltv = (loanAmount * BASIS_POINTS) / collateralValue;
    }

    /// @notice Check if a repo position is safely collateralised
    /// @param  loanAmount       Outstanding loan
    /// @param  collateralValue  Current collateral market value
    /// @param  haircutBps       Required haircut in basis points
    /// @return safe             True if collateral covers loan + haircut buffer
    /// @dev    Safe when: collateralValue >= loan / (1 - haircut%)
    ///         Equivalent to: LTV <= (1 - haircut%)
    function isSafe(
        uint256 loanAmount,
        uint256 collateralValue,
        uint256 haircutBps
    ) internal pure returns (bool safe) {
        require(haircutBps < BASIS_POINTS, "Haircut must be < 100%");
        uint256 minCollateral = (loanAmount * BASIS_POINTS) /
            (BASIS_POINTS - haircutBps);
        safe = collateralValue >= minCollateral;
    }

    // ─── Liquidation Math ────────────────────────────────────────

    /// @notice Split liquidation proceeds between lender, borrower, protocol
    /// @param  saleProceeds      USDC received from selling collateral
    /// @param  loanPlusInterest  Total owed to lender (principal + interest)
    /// @param  penaltyBps        Liquidation penalty on surplus (e.g. 200 = 2%)
    /// @return lenderAmount      USDC to credit to LendingPool
    /// @return borrowerSurplus   USDC returned to borrower (if any surplus)
    /// @return penalty           USDC kept by protocol as liquidation penalty
    /// @dev    If saleProceeds < loanPlusInterest:
    ///             lender takes all proceeds, borrower gets nothing
    ///         If saleProceeds > loanPlusInterest:
    ///             lender gets loan + interest + penalty
    ///             borrower gets remaining surplus
    ///         Penalty incentivises borrowers to respond to margin calls
    function liquidationSplit(
        uint256 saleProceeds,
        uint256 loanPlusInterest,
        uint256 penaltyBps
    ) internal pure returns (
        uint256 lenderAmount,
        uint256 borrowerSurplus,
        uint256 penalty
    ) {
        require(penaltyBps <= 1000, "Penalty max 10%");

        if (saleProceeds <= loanPlusInterest) {
            // Shortfall — lender absorbs the loss
            return (saleProceeds, 0, 0);
        }

        uint256 surplus = saleProceeds - loanPlusInterest;
        penalty         = (surplus * penaltyBps) / BASIS_POINTS;
        borrowerSurplus = surplus - penalty;
        lenderAmount    = loanPlusInterest + penalty;
    }

    // ─── Utility ─────────────────────────────────────────────────

    /// @notice Convert bond price (8 decimals) × token amount (18 decimals)
    ///         to USDC value (6 decimals)
    /// @param  tokenAmount  tTBILL tokens (18 decimals)
    /// @param  bondPrice    Oracle price (8 decimals, e.g. 98000000 = $980.00)
    /// @return usdcValue    Value in USDC (6 decimals)
    /// @dev    tokenAmount (18 dec) × bondPrice (8 dec) / 1e8 / 1e12
    ///         = USDC (6 decimals)
    ///         The 1e12 adjustment handles the 18→6 decimal conversion
    function bondValueInUSDC(
        uint256 tokenAmount,
        uint256 bondPrice
    ) internal pure returns (uint256 usdcValue) {
        // tokenAmount (18 dec) * bondPrice (8 dec) = 26 decimals
        // divide by 1e8 to normalize oracle price = 18 decimals
        // divide by 1e12 to convert from 18 dec to 6 dec (USDC)
        usdcValue = (tokenAmount * bondPrice) / 1e8 / 1e12;
    }
}
