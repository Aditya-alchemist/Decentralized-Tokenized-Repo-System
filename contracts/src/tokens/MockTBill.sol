// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title MockTBill — Tokenized US Treasury Bond (ERC-1400 behaviour)
/// @notice Simulates ERC-1400 via OpenZeppelin AccessControl:
///         - Only KYC_ROLE addresses can send or receive this token
///         - Replaces a manual ERC-1594 interface entirely for simplicity
///         - Bond metadata is attached on-chain (ERC-1643 style)
///         - Admin can pause all transfers in emergencies (ERC-1644 style)
contract MockTBill is ERC20, AccessControl, Pausable {

    // ─── Roles ───────────────────────────────────────────────────
    bytes32 public constant KYC_ROLE    = keccak256("KYC_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ─── Bond Metadata ───────────────────────────────────────────
    // Real-world bonds have strict identifiers and terms
    struct BondInfo {
        string  isin;           // International Securities Identification Number (e.g., "US912810TM84")
        uint256 faceValue;      // The payout at maturity (e.g., 1000e18 = $1,000)
        uint256 couponRateBps;  // Annual interest rate paid by the bond (e.g., 425 = 4.25%)
        uint256 maturityDate;   // Unix timestamp when the bond expires
        string  currency;       // e.g., "USD"
    }

    BondInfo public bondInfo;

    // ─── Events ──────────────────────────────────────────────────
    event BondInfoUpdated(string isin, uint256 couponRateBps, uint256 maturityDate);
    event KYCGranted(address indexed account);
    event KYCRevoked(address indexed account);

    // ─── Constructor ─────────────────────────────────────────────
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _isin,
        uint256 _faceValue,
        uint256 _couponRateBps,
        uint256 _maturityDate,
        address _admin
    ) ERC20(_name, _symbol) {
        // Grant the deployer (admin) all the super-user roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINTER_ROLE,        _admin);
        _grantRole(PAUSER_ROLE,        _admin);
        
        // The admin must be KYC'd by default so they can mint to themselves if needed
        _grantRole(KYC_ROLE,           _admin); 

        // Store the real-world terms of this specific bond
        bondInfo = BondInfo({
            isin:          _isin,
            faceValue:     _faceValue,
            couponRateBps: _couponRateBps,
            maturityDate:  _maturityDate,
            currency:      "USD"
        });
    }

    // ─── Minting ─────────────────────────────────────────────────
    
    /// @notice Creates new bond tokens and sends them to a user
    /// @dev The recipient must have the KYC_ROLE, or the transaction reverts
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(hasRole(KYC_ROLE, to), "Recipient is not KYC verified");
        _mint(to, amount);
    }

    // ─── The Core Security Logic (Transfer Restrictions) ─────────
    
    /// @notice This function is automatically called by OpenZeppelin during EVERY transfer
    /// @dev Overrides the standard ERC-20 `_update` to inject our KYC rules
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        // If 'from' is address(0), it's a mint. If 'to' is address(0), it's a burn.
        // We only want to check KYC on actual peer-to-peer transfers.
        if (from != address(0) && to != address(0)) {
            require(hasRole(KYC_ROLE, from), "Sender is not KYC verified");
            require(hasRole(KYC_ROLE, to),   "Recipient is not KYC verified");
        }
        
        // If the checks pass, execute the standard ERC-20 transfer
        super._update(from, to, amount);
    }

    // ─── KYC Management (Admin Only) ─────────────────────────────
    
    function grantKYC(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(KYC_ROLE, account);
        emit KYCGranted(account);
    }

    function revokeKYC(address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        revokeRole(KYC_ROLE, account);
        emit KYCRevoked(account);
    }

    function isKYC(address account) external view returns (bool) {
        return hasRole(KYC_ROLE, account);
    }

    // ─── Bond Metadata Management ────────────────────────────────

    function updateBondInfo(
        string memory _isin,
        uint256 _couponRateBps,
        uint256 _maturityDate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bondInfo.isin          = _isin;
        bondInfo.couponRateBps = _couponRateBps;
        bondInfo.maturityDate  = _maturityDate;
        emit BondInfoUpdated(_isin, _couponRateBps, _maturityDate);
    }

    // ─── Emergency Controls ──────────────────────────────────────
    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
