// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title BondPriceOracle
/// @notice Receives the T-Bill bond price pushed by an off-chain Python keeper bot
/// @dev Price is stored with 8 decimals to perfectly match Chainlink conventions
///      (e.g., $980.00 is represented as 9800000000)
contract BondPriceOracle is Ownable {

    // ─── State Variables ─────────────────────────────────────────
    uint256 private latestPrice;
    uint256 private lastUpdated;
    
    // If the Python bot goes down, the contract will refuse to use old data
    uint256 public stalePriceThreshold = 2 hours;

    // ─── Events ──────────────────────────────────────────────────
    event PriceUpdated(uint256 price, uint256 timestamp);
    event ThresholdUpdated(uint256 newThreshold);

    // ─── Constructor ─────────────────────────────────────────────
    /// @param initialOwner The address of your Python Keeper Bot
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─── Core Oracle Logic ───────────────────────────────────────

    /// @notice Pushes a new price to the blockchain
    /// @dev Only the owner (your Python script) can call this
    /// @param _price The new bond price (must have 8 decimals)
    function updatePrice(uint256 _price) external onlyOwner {
        require(_price > 0, "Price must be greater than zero");
        
        latestPrice = _price;
        lastUpdated = block.timestamp;
        
        emit PriceUpdated(_price, block.timestamp);
    }

    /// @notice Fetches the latest price for the MarginEngine and RepoVault
    /// @dev Reverts if the price hasn't been updated recently (protects the protocol)
    function getLatestPrice() external view returns (uint256) {
        require(latestPrice > 0, "Price not initialized yet");
        require(
            block.timestamp - lastUpdated <= stalePriceThreshold,
            "Oracle price is stale! Safety halt."
        );
        return latestPrice;
    }

    // ─── Utility & Admin ─────────────────────────────────────────

    /// @notice See exactly when the price was last pushed
    function getLastUpdated() external view returns (uint256) {
        return lastUpdated;
    }

    /// @notice Adjust how long a price is considered "fresh"
    function setStalePriceThreshold(uint256 _seconds) external onlyOwner {
        require(_seconds > 0, "Threshold must be > 0");
        stalePriceThreshold = _seconds;
        emit ThresholdUpdated(_seconds);
    }
}
