// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/RepoMath.sol";
import "../oracle/BondPriceOracle.sol";

/// @title RepoVault
/// @notice The core contract of the entire system.
///         Locks tTBILL collateral, opens repos, handles repayment,
///         issues margin calls, and liquidates unsafe positions.
contract RepoVault is ReentrancyGuard, Ownable, Pausable {

    // ─── Struct ──────────────────────────────────────────────────
    /// @notice Stores every detail about a single repo position
    struct RepoPosition {
        address borrower;
        uint256 collateralAmount;   // tTBILL locked (18 decimals)
        uint256 loanAmount;         // USDC borrowed (6 decimals)
        uint256 repoRateBps;        // annual interest rate in bps
        uint256 haircutBps;         // collateral haircut in bps
        uint256 openedAt;           // timestamp when repo was opened
        uint256 maturityDate;       // timestamp when repo expires
        uint256 termDays;           // number of days for this repo
        bool    isActive;           // false once closed/liquidated
        bool    marginCallActive;   // true when margin call is pending
        uint256 marginCallDeadline; // borrower must respond before this
    }

    // ─── State Variables ─────────────────────────────────────────
    IERC20          public immutable tTBILL;  // the bond token (collateral)
    IERC20          public immutable USDC;    // the loan token
    BondPriceOracle public immutable oracle;  // fetches live bond price

    address public marginEngine;  // set once after deployment
    address public lendingPool;   // set once after deployment

    uint256 public nextRepoId;                          // auto-incrementing ID
    uint256 public marginCallWindowSeconds = 4 hours;   // borrower response window
    uint256 public liquidationPenaltyBps   = 200;       // 2% penalty on surplus

    mapping(uint256 => RepoPosition) public repos;          // repoId → position
    mapping(address => uint256[])    public borrowerRepos;  // wallet → list of repoIds

    // ─── Events ──────────────────────────────────────────────────
    event RepoOpened(
        uint256 indexed repoId,
        address indexed borrower,
        uint256 collateralAmount,
        uint256 loanAmount,
        uint256 maturityDate
    );
    event RepoClosed(
        uint256 indexed repoId,
        address indexed borrower,
        uint256 totalRepaid
    );
    event MarginCallIssued(
        uint256 indexed repoId,
        uint256 deadline
    );
    event MarginCallMet(
        uint256 indexed repoId,
        uint256 additionalCollateral
    );
    event Liquidated(
        uint256 indexed repoId,
        uint256 saleProceeds,
        uint256 lenderAmount,
        uint256 borrowerSurplus,
        uint256 penalty
    );

    // ─── Modifiers ───────────────────────────────────────────────
    modifier onlyMarginEngine() {
        require(msg.sender == marginEngine, "Only MarginEngine");
        _;
    }

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "Only LendingPool");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────
    constructor(
        address _tTBILL,
        address _USDC,
        address _oracle,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_tTBILL != address(0), "Zero address: tTBILL");
        require(_USDC   != address(0), "Zero address: USDC");
        require(_oracle != address(0), "Zero address: oracle");

        tTBILL = IERC20(_tTBILL);
        USDC   = IERC20(_USDC);
        oracle = BondPriceOracle(_oracle);
    }

    // ─── One-Time Setup ──────────────────────────────────────────

    /// @notice Links MarginEngine — called once in Deploy.s.sol
    function setMarginEngine(address _engine) external onlyOwner {
        require(marginEngine == address(0), "Already set");
        require(_engine != address(0),      "Zero address");
        marginEngine = _engine;
    }

    /// @notice Links LendingPool — called once in Deploy.s.sol
    function setLendingPool(address _pool) external onlyOwner {
        require(lendingPool == address(0), "Already set");
        require(_pool != address(0),       "Zero address");
        lendingPool = _pool;
    }

    // ─── OPEN REPO ───────────────────────────────────────────────

    /// @notice Opens a new repo position
    /// @dev    Called ONLY by LendingPool after it has already sent USDC to borrower
    ///         Flow: Borrower calls LendingPool.requestRepo()
    ///               LendingPool sends USDC → Borrower
    ///               LendingPool calls RepoVault.openRepo()
    ///               RepoVault pulls tTBILL from Borrower into Vault
    function openRepo(
        address _borrower,
        uint256 _collateralAmount,
        uint256 _loanAmount,
        uint256 _repoRateBps,
        uint256 _haircutBps,
        uint256 _termDays
    ) external onlyLendingPool nonReentrant whenNotPaused returns (uint256 repoId) {

        require(_borrower         != address(0), "Zero address: borrower");
        require(_collateralAmount  > 0,          "Zero collateral");
        require(_loanAmount        > 0,          "Zero loan");
        require(_termDays          > 0,          "Zero term");

        // ── Step 1: Validate LTV using live oracle price ──────────
        // bondPrice has 8 decimals (e.g. 98000000 = $980.00)
        uint256 bondPrice     = oracle.getLatestPrice();

        // Convert collateral value to USDC terms (6 decimals)
        uint256 collateralVal = RepoMath.bondValueInUSDC(
            _collateralAmount,
            bondPrice
        );

        // Check that loan does not exceed max allowed by haircut
        uint256 maxLoan = RepoMath.maxLoanAmount(collateralVal, _haircutBps);
        require(_loanAmount <= maxLoan, "Loan amount exceeds max LTV");

        // ── Step 2: Pull tTBILL collateral from borrower ──────────
        // Borrower must have called tTBILL.approve(repoVault, amount) first
        require(
            tTBILL.transferFrom(_borrower, address(this), _collateralAmount),
            "Collateral transfer failed"
        );

        // ── Step 3: Record the position ───────────────────────────
        repoId = nextRepoId++;

        repos[repoId] = RepoPosition({
            borrower:           _borrower,
            collateralAmount:   _collateralAmount,
            loanAmount:         _loanAmount,
            repoRateBps:        _repoRateBps,
            haircutBps:         _haircutBps,
            openedAt:           block.timestamp,
            maturityDate:       block.timestamp + (_termDays * 1 days),
            termDays:           _termDays,
            isActive:           true,
            marginCallActive:   false,
            marginCallDeadline: 0
        });

        borrowerRepos[_borrower].push(repoId);

        emit RepoOpened(
            repoId,
            _borrower,
            _collateralAmount,
            _loanAmount,
            block.timestamp + (_termDays * 1 days)
        );
    }

    // ─── REPAY ───────────────────────────────────────────────────

    /// @notice Borrower repays loan + interest, gets their tTBILL back
    /// @dev    Borrower must approve USDC to this contract before calling
    function repayRepo(uint256 repoId)
        external nonReentrant whenNotPaused
    {
        RepoPosition storage pos = repos[repoId];

        require(pos.isActive,               "Repo is not active");
        require(pos.borrower == msg.sender,  "You did not open this repo");

        // ── Calculate total owed ──────────────────────────────────
        uint256 interest  = RepoMath.repoInterest(
            pos.loanAmount,
            pos.repoRateBps,
            pos.termDays
        );
        uint256 totalOwed = pos.loanAmount + interest;

        // ── Pull repayment USDC from borrower → LendingPool ───────
        require(
            USDC.transferFrom(msg.sender, lendingPool, totalOwed),
            "USDC repayment failed"
        );

        // ── Return tTBILL collateral to borrower ──────────────────
        require(
            tTBILL.transfer(pos.borrower, pos.collateralAmount),
            "Collateral return failed"
        );

        // ── Close the position ────────────────────────────────────
        pos.isActive = false;

        emit RepoClosed(repoId, msg.sender, totalOwed);
    }

    // ─── MARGIN CALL: ISSUE ──────────────────────────────────────

    /// @notice MarginEngine calls this when LTV breaches 90% threshold
    /// @dev    Gives borrower a 4-hour window to top up collateral
    function issueMarginCall(uint256 repoId)
        external onlyMarginEngine
    {
        RepoPosition storage pos = repos[repoId];

        require(pos.isActive,          "Repo is not active");
        require(!pos.marginCallActive, "Margin call already active");

        pos.marginCallActive   = true;
        pos.marginCallDeadline = block.timestamp + marginCallWindowSeconds;

        emit MarginCallIssued(repoId, pos.marginCallDeadline);
    }

    // ─── MARGIN CALL: MEET ───────────────────────────────────────

    /// @notice Borrower deposits extra tTBILL to bring LTV back to safety
    /// @dev    Must be called before marginCallDeadline expires
    function meetMarginCall(
        uint256 repoId,
        uint256 additionalCollateral
    ) external nonReentrant {
        RepoPosition storage pos = repos[repoId];

        require(pos.isActive,                              "Repo is not active");
        require(pos.marginCallActive,                      "No margin call active");
        require(block.timestamp <= pos.marginCallDeadline, "Margin call window expired");
        require(additionalCollateral > 0,                  "Zero collateral");

        // Pull extra tTBILL from borrower into vault
        require(
            tTBILL.transferFrom(msg.sender, address(this), additionalCollateral),
            "Top-up transfer failed"
        );

        // Update position
        pos.collateralAmount  += additionalCollateral;
        pos.marginCallActive   = false;
        pos.marginCallDeadline = 0;

        emit MarginCallMet(repoId, additionalCollateral);
    }

    // ─── LIQUIDATION ─────────────────────────────────────────────

    /// @notice MarginEngine calls this when:
    ///         1. Margin call window expires without borrower topping up, OR
    ///         2. LTV jumps directly above 95% (critical — no time for margin call)
    function liquidate(uint256 repoId)
        external onlyMarginEngine nonReentrant
    {
        RepoPosition storage pos = repos[repoId];
        require(pos.isActive, "Repo is not active");

        // ── Calculate what borrower owes ──────────────────────────
        uint256 interest  = RepoMath.repoInterest(
            pos.loanAmount,
            pos.repoRateBps,
            pos.termDays
        );
        uint256 totalOwed = pos.loanAmount + interest;

        // ── Value the collateral at current oracle price ───────────
        uint256 bondPrice    = oracle.getLatestPrice();
        uint256 saleProceeds = RepoMath.bondValueInUSDC(
            pos.collateralAmount,
            bondPrice
        );

        // ── Split the proceeds ────────────────────────────────────
        (
            uint256 lenderAmount,
            uint256 borrowerSurplus,
            uint256 penalty
        ) = RepoMath.liquidationSplit(
            saleProceeds,
            totalOwed,
            liquidationPenaltyBps
        );

        // ── Close the position BEFORE any transfers ───────────────
        // This follows the Checks-Effects-Interactions pattern
        // Prevents reentrancy attacks
        pos.isActive = false;

        // ── Credit LendingPool with lender's share ────────────────
        (bool ok,) = lendingPool.call(
            abi.encodeWithSignature(
                "creditLiquidation(uint256,uint256)",
                repoId,
                lenderAmount
            )
        );
        require(ok, "Liquidation credit to LendingPool failed");

        // ── Return any surplus to borrower ────────────────────────
        if (borrowerSurplus > 0) {
            USDC.transfer(pos.borrower, borrowerSurplus);
        }

        emit Liquidated(
            repoId,
            saleProceeds,
            lenderAmount,
            borrowerSurplus,
            penalty
        );
    }

    // ─── VIEW FUNCTIONS ──────────────────────────────────────────

    /// @notice Get full details of a repo position
    function getRepo(uint256 repoId)
        external view returns (RepoPosition memory)
    {
        return repos[repoId];
    }

    /// @notice Get all repo IDs opened by a specific borrower
    function getBorrowerRepos(address borrower)
        external view returns (uint256[] memory)
    {
        return borrowerRepos[borrower];
    }

    /// @notice Get current USDC value of a repo's collateral
    function getCollateralValue(uint256 repoId)
        external view returns (uint256)
    {
        RepoPosition memory pos = repos[repoId];
        uint256 bondPrice = oracle.getLatestPrice();
        return RepoMath.bondValueInUSDC(pos.collateralAmount, bondPrice);
    }

    /// @notice Get total USDC owed for a repo (principal + interest)
    function getTotalOwed(uint256 repoId)
        external view returns (uint256)
    {
        RepoPosition memory pos = repos[repoId];
        uint256 interest = RepoMath.repoInterest(
            pos.loanAmount,
            pos.repoRateBps,
            pos.termDays
        );
        return pos.loanAmount + interest;
    }

    /// @notice Check if a repo is currently safe (collateral covers loan)
    function isPositionSafe(uint256 repoId)
        external view returns (bool)
    {
        RepoPosition memory pos = repos[repoId];
        if (!pos.isActive) return false;
        uint256 bondPrice     = oracle.getLatestPrice();
        uint256 collateralVal = RepoMath.bondValueInUSDC(
            pos.collateralAmount,
            bondPrice
        );
        return RepoMath.isSafe(
            pos.loanAmount,
            collateralVal,
            pos.haircutBps
        );
    }

    // ─── ADMIN ───────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setMarginCallWindow(uint256 _seconds) external onlyOwner {
        require(_seconds >= 1 hours,  "Min 1 hour window");
        require(_seconds <= 24 hours, "Max 24 hour window");
        marginCallWindowSeconds = _seconds;
    }

    function setLiquidationPenalty(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "Max 10% penalty");
        liquidationPenaltyBps = _bps;
    }
}
