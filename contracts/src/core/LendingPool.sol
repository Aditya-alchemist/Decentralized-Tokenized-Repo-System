// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../tokens/RepoPoolToken.sol";

/// @title LendingPool
/// @notice Entry point for lenders and borrowers.
///         Lenders deposit USDC → receive rpUSDC shares that grow in value.
///         Borrowers request repo loans against tTBILL collateral.
interface IRepoVault {
    function openRepo(
        address _borrower,
        uint256 _collateralAmount,
        uint256 _loanAmount,
        uint256 _repoRateBps,
        uint256 _haircutBps,
        uint256 _termDays
    ) external returns (uint256);
}

contract LendingPool is ReentrancyGuard, Ownable, Pausable {

    // ─── State ───────────────────────────────────────────────────
    IERC20        public immutable USDC;
    RepoPoolToken public immutable rpUSDC;
    address       public           repoVault;

    uint256 public totalLoaned;
    uint256 public defaultRepoRateBps = 550;
    uint256 public defaultHaircutBps  = 500;
    uint256 public defaultTermDays    = 7;

    // ─── Events ──────────────────────────────────────────────────
    event Deposited(address indexed lender, uint256 usdcAmount, uint256 sharesIssued);
    event Withdrawn(address indexed lender, uint256 usdcReturned, uint256 sharesBurned);
    event LoanIssued(address indexed borrower, uint256 loanAmount, uint256 indexed repoId);
    event RepaymentReceived(uint256 principal, uint256 interest);
    event LiquidationCredited(uint256 indexed repoId, uint256 amount);

    // ─── Constructor ─────────────────────────────────────────────
    constructor(
        address _USDC,
        address _rpUSDC,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_USDC   != address(0), "Zero address: USDC");
        require(_rpUSDC != address(0), "Zero address: rpUSDC");
        USDC   = IERC20(_USDC);
        rpUSDC = RepoPoolToken(_rpUSDC);
    }

    // ─── Setup ───────────────────────────────────────────────────
    function setRepoVault(address _vault) external onlyOwner {
        require(repoVault == address(0), "Already set");
        require(_vault    != address(0), "Zero address");
        repoVault = _vault;
    }

    // ─── LENDER: Deposit ─────────────────────────────────────────

    /// @notice Lender deposits USDC, receives rpUSDC shares
    /// @dev    First depositor gets 1:1. Later depositors priced by sharePrice.
    function deposit(uint256 usdcAmount)
        external nonReentrant whenNotPaused
    {
        require(usdcAmount > 0, "Cannot deposit zero");

        uint256 shares = _usdcToShares(usdcAmount);

        require(
            USDC.transferFrom(msg.sender, address(this), usdcAmount),
            "USDC transfer failed"
        );

        rpUSDC.mint(msg.sender, shares);

        emit Deposited(msg.sender, usdcAmount, shares);
    }

    // ─── LENDER: Withdraw ────────────────────────────────────────

    /// @notice Lender burns rpUSDC shares, receives USDC + earned interest
    function withdraw(uint256 shareAmount)
        external nonReentrant whenNotPaused
    {
        require(shareAmount > 0,                             "Cannot withdraw zero");
        require(rpUSDC.balanceOf(msg.sender) >= shareAmount, "Insufficient rpUSDC");

        uint256 usdcOut = _sharesToUSDC(shareAmount);
        require(
            USDC.balanceOf(address(this)) >= usdcOut,
            "Insufficient liquidity wait for repayments"
        );

        // CEI: burn shares BEFORE transfer
        rpUSDC.burn(msg.sender, shareAmount);

        require(USDC.transfer(msg.sender, usdcOut), "USDC transfer failed");

        emit Withdrawn(msg.sender, usdcOut, shareAmount);
    }

    // ─── BORROWER: Request Repo ───────────────────────────────────

    /// @notice Borrower requests a USDC loan against tTBILL collateral
    /// @dev    Borrower must approve tTBILL to RepoVault BEFORE calling this
    function requestRepo(
        uint256 collateralAmount,
        uint256 loanAmount
    ) external nonReentrant whenNotPaused returns (uint256 repoId) {
        require(loanAmount       > 0,                 "Zero loan");
        require(collateralAmount > 0,                 "Zero collateral");
        require(loanAmount <= availableLiquidity(),    "Insufficient liquidity");
        require(repoVault  != address(0),             "Vault not configured");

        // Update accounting before transfer (CEI)
        totalLoaned += loanAmount;

        // Send USDC loan to borrower
        require(
            USDC.transfer(msg.sender, loanAmount),
            "Loan transfer failed"
        );

        // Tell vault to lock borrower's tTBILL collateral
        repoId = IRepoVault(repoVault).openRepo(
            msg.sender,
            collateralAmount,
            loanAmount,
            defaultRepoRateBps,
            defaultHaircutBps,
            defaultTermDays
        );

        emit LoanIssued(msg.sender, loanAmount, repoId);
    }

    // ─── CALLED BY RepoVault: Repayment ──────────────────────────

    /// @notice RepoVault calls this after DVP settlement completes
    /// @dev    FIX: This was never called in original repayRepo
    ///         Without this, totalLoaned never decreases → sharePrice wrong forever
    ///         USDC already arrived via RepoSettlement cash leg before this is called
    function receiveRepayment(uint256 principal, uint256 interest)
        external
    {
        require(msg.sender == repoVault,   "Only RepoVault");
        require(totalLoaned >= principal,  "Repayment exceeds loaned");
        totalLoaned -= principal;
        // interest sits in this contract's USDC balance
        // totalPoolValue grows → sharePrice increases → lenders earn yield
        emit RepaymentReceived(principal, interest);
    }

    // ─── CALLED BY RepoVault: Liquidation ────────────────────────

    /// @notice RepoVault calls this after sending liquidation USDC to this contract
    /// @dev    USDC transfer happens in RepoVault.liquidate() BEFORE this is called
    ///         This function only updates the accounting number
    function creditLiquidation(uint256 repoId, uint256 amount)
        external
    {
        require(msg.sender == repoVault, "Only RepoVault");
        if (totalLoaned >= amount) {
            totalLoaned -= amount;
        } else {
            totalLoaned = 0;
        }
        emit LiquidationCredited(repoId, amount);
    }

    // ─── SHARE MATH ──────────────────────────────────────────────

    /// @notice 1 rpUSDC = how many USDC right now
    function sharePrice() public view returns (uint256) {
        uint256 supply = rpUSDC.totalSupply();
        if (supply == 0) return 1e6;
        return (totalPoolValue() * 1e6) / supply;
    }

    function _usdcToShares(uint256 usdcAmount) internal view returns (uint256) {
        uint256 supply = rpUSDC.totalSupply();
        if (supply == 0) return usdcAmount;
        return (usdcAmount * supply) / totalPoolValue();
    }

    function _sharesToUSDC(uint256 shareAmount) internal view returns (uint256) {
        uint256 supply = rpUSDC.totalSupply();
        if (supply == 0) return 0;
        return (shareAmount * totalPoolValue()) / supply;
    }

    // ─── VIEWS ───────────────────────────────────────────────────

    /// @notice Total USDC the pool controls (balance + lent out)
    function totalPoolValue() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + totalLoaned;
    }

    /// @notice USDC available to lend right now
    function availableLiquidity() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice How much USDC a lender's rpUSDC is worth right now
    function getLenderBalance(address lender)
        external view returns (uint256 shares, uint256 usdcValue)
    {
        shares    = rpUSDC.balanceOf(lender);
        usdcValue = _sharesToUSDC(shares);
    }

    // ─── ADMIN ───────────────────────────────────────────────────
    function setDefaultTerms(
        uint256 _rateBps,
        uint256 _haircutBps,
        uint256 _termDays
    ) external onlyOwner {
        require(_rateBps    <= 2000, "Rate max 20%");
        require(_haircutBps <= 5000, "Haircut max 50%");
        require(_termDays   >= 1,    "Min 1 day");
        defaultRepoRateBps = _rateBps;
        defaultHaircutBps  = _haircutBps;
        defaultTermDays    = _termDays;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
