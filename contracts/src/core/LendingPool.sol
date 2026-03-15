// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../tokens/RepoPoolToken.sol";

/// @title LendingPool
/// @notice The entry point for all users.
///         Lenders deposit USDC → receive rpUSDC shares that grow in value.
///         Borrowers request repo loans against tTBILL collateral.
///
/// @dev SHARE PRICE MATH:
///      sharePrice = totalPoolValue / rpUSDC.totalSupply()
///      As interest accumulates in the pool, totalPoolValue grows
///      while supply stays the same → each share is worth more USDC

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

    uint256 public totalLoaned;              // USDC currently lent out to borrowers
    uint256 public defaultRepoRateBps = 550; // 5.5% annual repo rate
    uint256 public defaultHaircutBps  = 500; // 5% haircut on collateral
    uint256 public defaultTermDays    = 7;   // 7-day repo term

    // ─── Events ──────────────────────────────────────────────────
    event Deposited(
        address indexed lender,
        uint256 usdcAmount,
        uint256 sharesIssued
    );
    event Withdrawn(
        address indexed lender,
        uint256 usdcReturned,
        uint256 sharesBurned
    );
    event LoanIssued(
        address indexed borrower,
        uint256 loanAmount,
        uint256 indexed repoId
    );
    event RepaymentReceived(
        uint256 principal,
        uint256 interest
    );
    event LiquidationCredited(
        uint256 indexed repoId,
        uint256 amount
    );

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

    // ─── One-Time Setup ──────────────────────────────────────────
    function setRepoVault(address _vault) external onlyOwner {
        require(repoVault == address(0), "Already set");
        require(_vault != address(0),    "Zero address");
        repoVault = _vault;
    }

    // ─── LENDER: Deposit USDC → receive rpUSDC ───────────────────

    /// @notice Lender deposits USDC into the pool
    /// @dev    First depositor always gets 1:1 shares
    ///         Later depositors get shares based on current pool value
    ///         This ensures fair entry regardless of when you deposit
    function deposit(uint256 usdcAmount)
        external nonReentrant whenNotPaused
    {
        require(usdcAmount > 0, "Cannot deposit zero");

        // Calculate how many rpUSDC shares to mint
        uint256 shares = _usdcToShares(usdcAmount);

        // Pull USDC from lender into this contract
        require(
            USDC.transferFrom(msg.sender, address(this), usdcAmount),
            "USDC transfer failed"
        );

        // Mint rpUSDC shares to lender
        rpUSDC.mint(msg.sender, shares);

        emit Deposited(msg.sender, usdcAmount, shares);
    }

    // ─── LENDER: Burn rpUSDC → receive USDC + earned interest ────

    /// @notice Lender withdraws their USDC + share of interest
    /// @dev    Burns rpUSDC shares. The USDC returned is proportional
    ///         to current pool value — more than deposited if interest accrued
    function withdraw(uint256 shareAmount)
        external nonReentrant whenNotPaused
    {
        require(shareAmount > 0,                              "Cannot withdraw zero");
        require(rpUSDC.balanceOf(msg.sender) >= shareAmount,  "Insufficient rpUSDC balance");

        // Calculate how much USDC these shares are worth right now
        uint256 usdcOut = _sharesToUSDC(shareAmount);
        require(
            USDC.balanceOf(address(this)) >= usdcOut,
            "Insufficient pool liquidity — wait for repayments"
        );

        // Burn shares first (Checks-Effects-Interactions pattern)
        rpUSDC.burn(msg.sender, shareAmount);

        // Send USDC to lender
        require(USDC.transfer(msg.sender, usdcOut), "USDC transfer failed");

        emit Withdrawn(msg.sender, usdcOut, shareAmount);
    }

    // ─── BORROWER: Request a repo loan ───────────────────────────

    /// @notice Borrower requests a USDC loan against tTBILL collateral
    /// @dev    Step 1: This contract sends USDC loan to borrower
    ///         Step 2: This contract tells RepoVault to lock borrower's tTBILL
    ///         Borrower must approve tTBILL to RepoVault BEFORE calling this
    function requestRepo(
        uint256 collateralAmount,
        uint256 loanAmount
    ) external nonReentrant whenNotPaused returns (uint256 repoId) {
        require(loanAmount        > 0,                    "Zero loan amount");
        require(collateralAmount  > 0,                    "Zero collateral");
        require(loanAmount <= availableLiquidity(),        "Insufficient pool liquidity");
        require(repoVault != address(0),                  "Vault not configured");

        // Track how much is lent out
        totalLoaned += loanAmount;

        // Step 1: Send USDC loan to borrower RIGHT NOW
        require(
            USDC.transfer(msg.sender, loanAmount),
            "Loan transfer failed"
        );

        // Step 2: Tell vault to pull tTBILL collateral from borrower
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

    // ─── CALLED BY RepoVault on repayment ────────────────────────

    /// @notice RepoVault sends USDC repayment here after borrower repays
    /// @dev    Interest stays in the pool → increases rpUSDC share value
    ///         This is how lenders earn yield passively
    function receiveRepayment(uint256 principal, uint256 interest)
        external
    {
        require(msg.sender == repoVault, "Only RepoVault");
        require(totalLoaned >= principal, "Repayment exceeds loaned amount");
        totalLoaned -= principal;
        // Interest is now sitting in this contract's USDC balance
        // It automatically increases totalPoolValue → increases share price
        emit RepaymentReceived(principal, interest);
    }

    // ─── CALLED BY RepoVault on liquidation ──────────────────────

    /// @notice RepoVault credits this pool after a liquidation
    /// @dev    The liquidated proceeds are already in this contract's balance
    ///         (sent by RepoVault during the liquidation call)
    ///         We just update the accounting here
    function creditLiquidation(uint256 repoId, uint256 amount)
        external
    {
        require(msg.sender == repoVault, "Only RepoVault");
        if (totalLoaned >= amount) {
            totalLoaned -= amount;
        } else {
            totalLoaned = 0; // Prevent underflow in edge cases
        }
        emit LiquidationCredited(repoId, amount);
    }

    // ─── SHARE PRICE MATH ────────────────────────────────────────

    /// @notice 1 rpUSDC = how many USDC right now
    /// @dev    Starts at $1.00 (1e6), grows as interest enters the pool
    function sharePrice() public view returns (uint256) {
        uint256 supply = rpUSDC.totalSupply();
        if (supply == 0) return 1e6; // $1.00 initial price (USDC has 6 decimals)
        return (totalPoolValue() * 1e6) / supply;
    }

    /// @notice How many shares should I mint for X USDC deposited?
    function _usdcToShares(uint256 usdcAmount) internal view returns (uint256) {
        uint256 supply = rpUSDC.totalSupply();
        if (supply == 0) return usdcAmount; // 1:1 for first depositor
        return (usdcAmount * supply) / totalPoolValue();
    }

    /// @notice How much USDC is X shares worth right now?
    function _sharesToUSDC(uint256 shareAmount) internal view returns (uint256) {
        uint256 supply = rpUSDC.totalSupply();
        if (supply == 0) return 0;
        return (shareAmount * totalPoolValue()) / supply;
    }

    // ─── VIEWS ───────────────────────────────────────────────────

    /// @notice Total USDC the pool controls (wallet balance + lent out)
    function totalPoolValue() public view returns (uint256) {
        return USDC.balanceOf(address(this)) + totalLoaned;
    }

    /// @notice USDC sitting in the pool right now available to lend
    function availableLiquidity() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice How much USDC a lender's rpUSDC balance is worth right now
    function getLenderBalance(address lender)
        external view returns (uint256 shares, uint256 usdcValue)
    {
        shares    = rpUSDC.balanceOf(lender);
        usdcValue = _sharesToUSDC(shares);
    }

    // ─── ADMIN ───────────────────────────────────────────────────

    /// @notice Update the default terms applied to every new repo
    function setDefaultTerms(
        uint256 _rateBps,
        uint256 _haircutBps,
        uint256 _termDays
    ) external onlyOwner {
        require(_rateBps    <= 2000, "Rate max 20%");
        require(_haircutBps <= 5000, "Haircut max 50%");
        require(_termDays   >= 1,    "Min 1 day term");
        defaultRepoRateBps = _rateBps;
        defaultHaircutBps  = _haircutBps;
        defaultTermDays    = _termDays;
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
