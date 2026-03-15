// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../libraries/RepoMath.sol";
import "../oracle/BondPriceOracle.sol";

/// @title MarginEngine
/// @notice Monitors the health of every active repo position.
///         Called by the Python keeper bot after every oracle price update.
///         Automatically triggers margin calls and liquidations.
///
/// @dev    This is the automated risk manager of the protocol.
///         In traditional finance, this job is done by a human risk desk.
///         Here it is done by pure math, with no human discretion.

interface IRepoVaultMargin {
    struct RepoPosition {
        address borrower;
        uint256 collateralAmount;
        uint256 loanAmount;
        uint256 repoRateBps;
        uint256 haircutBps;
        uint256 openedAt;
        uint256 maturityDate;
        uint256 termDays;
        bool    isActive;
        bool    marginCallActive;
        uint256 marginCallDeadline;
    }
    function getRepo(uint256 repoId) external view returns (RepoPosition memory);
    function issueMarginCall(uint256 repoId) external;
    function liquidate(uint256 repoId) external;
}

contract MarginEngine is Ownable {

    // ─── State ───────────────────────────────────────────────────
    BondPriceOracle  public immutable oracle;
    IRepoVaultMargin public immutable vault;

    // LTV thresholds in basis points
    uint256 public marginCallThresholdBps  = 9000; // 90% LTV → margin call
    uint256 public liquidationThresholdBps = 9500; // 95% LTV → liquidate

    // ─── Events ──────────────────────────────────────────────────
    event MarginCallTriggered(
        uint256 indexed repoId,
        uint256 currentLTV,
        uint256 deadline
    );
    event LiquidationTriggered(
        uint256 indexed repoId,
        uint256 currentLTV
    );
    event RepoHealthy(
        uint256 indexed repoId,
        uint256 currentLTV
    );

    // ─── Constructor ─────────────────────────────────────────────
    constructor(
        address _oracle,
        address _vault,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_oracle != address(0), "Zero address: oracle");
        require(_vault  != address(0), "Zero address: vault");
        oracle = BondPriceOracle(_oracle);
        vault  = IRepoVaultMargin(_vault);
    }

    // ─── CHECK SINGLE REPO ───────────────────────────────────────

    /// @notice Checks health of a single repo and acts accordingly
    /// @dev    Called by Python keeper bot after every oracle price push
    ///         Three possible outcomes:
    ///         1. Healthy      → emit RepoHealthy, do nothing
    ///         2. LTV >= 90%   → issue margin call, give borrower 4 hours
    ///         3. LTV >= 95%   → liquidate immediately
    ///         4. MC expired   → liquidate (borrower ignored warning)
    function checkRepo(uint256 repoId) external {
        IRepoVaultMargin.RepoPosition memory pos = vault.getRepo(repoId);

        // Skip inactive repos silently — no revert, just return
        if (!pos.isActive) return;

        // Get current bond price from oracle
        uint256 bondPrice     = oracle.getLatestPrice();

        // Convert collateral to USDC value using decimal-safe math
        uint256 collateralVal = RepoMath.bondValueInUSDC(
            pos.collateralAmount,
            bondPrice
        );

        // Calculate current LTV in basis points
        uint256 ltv = RepoMath.currentLTV(pos.loanAmount, collateralVal);

        // ── Priority 1: Margin call window expired → liquidate ────
        if (
            pos.marginCallActive &&
            block.timestamp > pos.marginCallDeadline
        ) {
            emit LiquidationTriggered(repoId, ltv);
            vault.liquidate(repoId);
            return;
        }

        // ── Priority 2: LTV critical → immediate liquidation ──────
        if (ltv >= liquidationThresholdBps && !pos.marginCallActive) {
            emit LiquidationTriggered(repoId, ltv);
            vault.liquidate(repoId);
            return;
        }

        // ── Priority 3: LTV elevated → issue margin call ──────────
        if (
            ltv >= marginCallThresholdBps  &&
            ltv <  liquidationThresholdBps &&
            !pos.marginCallActive
        ) {
            uint256 deadline = block.timestamp + 4 hours;
            emit MarginCallTriggered(repoId, ltv, deadline);
            vault.issueMarginCall(repoId);
            return;
        }

        // ── All good ──────────────────────────────────────────────
        emit RepoHealthy(repoId, ltv);
    }

    // ─── BATCH CHECK ─────────────────────────────────────────────

    /// @notice Check multiple repos in one transaction
    /// @dev    Python keeper passes all active repoIds in one call
    ///         This saves gas vs calling checkRepo() one by one
    function checkRepos(uint256[] calldata repoIds) external {
        for (uint256 i = 0; i < repoIds.length; i++) {
            this.checkRepo(repoIds[i]);
        }
    }

    // ─── VIEWS ───────────────────────────────────────────────────

    /// @notice Get current LTV of a repo in basis points
    function getCurrentLTV(uint256 repoId)
        external view returns (uint256)
    {
        IRepoVaultMargin.RepoPosition memory pos = vault.getRepo(repoId);
        require(pos.isActive, "Repo not active");
        uint256 bondPrice     = oracle.getLatestPrice();
        uint256 collateralVal = RepoMath.bondValueInUSDC(
            pos.collateralAmount,
            bondPrice
        );
        return RepoMath.currentLTV(pos.loanAmount, collateralVal);
    }

    /// @notice Quick check — is this repo currently at risk?
    function isAtRisk(uint256 repoId) external view returns (bool) {
        IRepoVaultMargin.RepoPosition memory pos = vault.getRepo(repoId);
        if (!pos.isActive) return false;
        uint256 bondPrice     = oracle.getLatestPrice();
        uint256 collateralVal = RepoMath.bondValueInUSDC(
            pos.collateralAmount,
            bondPrice
        );
        uint256 ltv = RepoMath.currentLTV(pos.loanAmount, collateralVal);
        return ltv >= marginCallThresholdBps;
    }

    // ─── ADMIN ───────────────────────────────────────────────────

    /// @notice Update the LTV thresholds
    /// @dev    marginCall must always be lower than liquidation
    ///         e.g. warn at 85%, liquidate at 92%
    function setThresholds(
        uint256 _mcBps,
        uint256 _liqBps
    ) external onlyOwner {
        require(_mcBps  >= 5000,    "Min 50% LTV for margin call");
        require(_mcBps  <  _liqBps, "MC threshold must be < liquidation");
        require(_liqBps <= 10000,   "Max 100% LTV");
        marginCallThresholdBps  = _mcBps;
        liquidationThresholdBps = _liqBps;
    }
}
