// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title RepoPoolToken — rpUSDC
/// @notice ERC-20 share token representing a lender's proportional
///         claim on the LendingPool's total USDC + accrued interest
///
/// @dev HOW SHARE VALUE GROWS:
///      Day 0:  Pool has $10,000 USDC.  1,000 rpUSDC minted.  1 rpUSDC = $10.00
///      Day 7:  Borrower repays $550 interest. Pool now has $10,550 USDC.
///              Still 1,000 rpUSDC in circulation.
///              1 rpUSDC = $10.55  ← lender's profit without doing anything
///
/// @dev SECURITY:
///      Only the LendingPool contract can mint or burn rpUSDC.
///      No individual user or admin can create or destroy shares directly.
///      This prevents anyone from inflating or deflating their own share.

contract RepoPoolToken is ERC20, Ownable {

    // ─── State ───────────────────────────────────────────────────
    address public lendingPool;

    // ─── Events ──────────────────────────────────────────────────
    event LendingPoolSet(address indexed lendingPool);

    // ─── Modifier ────────────────────────────────────────────────
    /// @notice Blocks anyone other than the LendingPool from minting/burning
    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Only LendingPool can do this");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────
    /// @param _initialOwner Your deployer wallet (needed to call setLendingPool)
    constructor(address _initialOwner)
        ERC20("Repo Pool USDC", "rpUSDC")
        Ownable(_initialOwner)
    {}

    // ─── One-Time Setup ──────────────────────────────────────────

    /// @notice Links this token to the LendingPool contract
    /// @dev Called ONCE in Deploy.s.sol right after LendingPool is deployed
    ///      The "Already set" guard prevents the address from being changed later
    ///      This makes the system immutable once deployed — no rug pull possible
    function setLendingPool(address _lendingPool) external onlyOwner {
        require(lendingPool == address(0), "LendingPool already set");
        require(_lendingPool != address(0), "Cannot set zero address");
        lendingPool = _lendingPool;
        emit LendingPoolSet(_lendingPool);
    }

    // ─── Mint / Burn (LendingPool Only) ──────────────────────────

    /// @notice Creates rpUSDC shares when a lender deposits USDC
    /// @dev Called by LendingPool.deposit()
    function mint(address to, uint256 amount) external onlyLendingPool {
        _mint(to, amount);
    }

    /// @notice Destroys rpUSDC shares when a lender withdraws USDC
    /// @dev Called by LendingPool.withdraw()
    function burn(address from, uint256 amount) external onlyLendingPool {
        _burn(from, amount);
    }
}
