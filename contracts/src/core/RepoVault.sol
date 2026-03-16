// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/RepoMath.sol";
import "../oracle/BondPriceOracle.sol";

interface ILendingPool {
    function receiveRepayment(uint256 principal, uint256 interest) external;
    function creditLiquidation(uint256 repoId, uint256 amount) external;
}

interface IRepoSettlement {
    function createTicket(
        address seller,
        address buyer,
        uint256 bondAmount,
        uint256 cashAmount,
        uint256 expirySeconds
    ) external returns (uint256);
    function executeSettlement(uint256 ticketId) external;
}

/// @title RepoVault
/// @notice The core contract of the entire system.
///         Locks tTBILL collateral, opens repos, handles repayment,
///         issues margin calls, and liquidates unsafe positions.
contract RepoVault is ReentrancyGuard, Ownable, Pausable {

    // ─── Struct ──────────────────────────────────────────────────
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

    // ─── State ───────────────────────────────────────────────────
    IERC20          public immutable tTBILL;
    IERC20          public immutable USDC;
    BondPriceOracle public immutable oracle;

    address public marginEngine;
    address public lendingPool;
    address public repoSettlement;   // ← ADDED

    uint256 public nextRepoId;
    uint256 public marginCallWindowSeconds = 4 hours;
    uint256 public liquidationPenaltyBps   = 200;

    mapping(uint256 => RepoPosition) public repos;
    mapping(address => uint256[])    public borrowerRepos;

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
    event MarginCallIssued(uint256 indexed repoId, uint256 deadline);
    event MarginCallMet(uint256 indexed repoId, uint256 additionalCollateral);
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
    function setMarginEngine(address _engine) external onlyOwner {
        require(marginEngine == address(0), "Already set");
        require(_engine      != address(0), "Zero address");
        marginEngine = _engine;
    }

    function setLendingPool(address _pool) external onlyOwner {
        require(lendingPool == address(0), "Already set");
        require(_pool       != address(0), "Zero address");
        lendingPool = _pool;
    }

    /// @notice Links RepoSettlement — called once in Deploy.s.sol
    function setRepoSettlement(address _settlement) external onlyOwner {
        require(repoSettlement == address(0), "Already set");
        require(_settlement    != address(0), "Zero address");
        repoSettlement = _settlement;
    }

    // ─── OPEN REPO ───────────────────────────────────────────────

    /// @notice Opens a new repo position
    /// @dev    Called ONLY by LendingPool after it has already sent USDC to borrower
    function openRepo(
        address _borrower,
        uint256 _collateralAmount,
        uint256 _loanAmount,
        uint256 _repoRateBps,
        uint256 _haircutBps,
        uint256 _termDays
    ) external onlyLendingPool nonReentrant whenNotPaused returns (uint256 repoId) {

        require(_borrower         != address(0), "Zero address: borrower");
        require(_collateralAmount  > 0,           "Zero collateral");
        require(_loanAmount        > 0,           "Zero loan");
        require(_termDays          > 0,           "Zero term");

        // Validate LTV using live oracle price
        uint256 bondPrice     = oracle.getLatestPrice();
        uint256 collateralVal = RepoMath.bondValueInUSDC(
            _collateralAmount,
            bondPrice
        );
        uint256 maxLoan = RepoMath.maxLoanAmount(collateralVal, _haircutBps);
        require(_loanAmount <= maxLoan, "Loan exceeds max LTV");

        // Pull tTBILL collateral from borrower into vault
        require(
            tTBILL.transferFrom(_borrower, address(this), _collateralAmount),
            "Collateral transfer failed"
        );

        // Record the position
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

    /// @notice Borrower repays loan + interest, gets tTBILL back atomically
    /// @dev    FIX 1: Uses RepoSettlement for atomic DVP instead of sequential transfers
    ///         FIX 2: Calls receiveRepayment() so LendingPool updates totalLoaned
    ///
    ///         Borrower must approve USDC    to RepoSettlement before calling
    ///         This vault approves   tTBILL  to RepoSettlement inside this function
    function repayRepo(uint256 repoId)
        external nonReentrant whenNotPaused
    {
        RepoPosition storage pos = repos[repoId];

        require(pos.isActive,               "Repo is not active");
        require(pos.borrower == msg.sender, "You did not open this repo");
        require(repoSettlement != address(0), "Settlement not configured");

        // Calculate total owed
        uint256 interest  = RepoMath.repoInterest(
            pos.loanAmount,
            pos.repoRateBps,
            pos.termDays
        );
        uint256 totalOwed = pos.loanAmount + interest;

        // ── CEI: Close position BEFORE any external calls ─────────
        uint256 collateralToReturn = pos.collateralAmount;
        address borrower           = pos.borrower;
        pos.isActive               = false;

        // ── Approve RepoSettlement to move our tTBILL ─────────────
        tTBILL.approve(repoSettlement, collateralToReturn);

        // ── Create DVP settlement ticket ──────────────────────────
        // seller = this vault  (delivers tTBILL → borrower)
        // buyer  = borrower    (delivers USDC   → lendingPool)
        uint256 ticketId = IRepoSettlement(repoSettlement).createTicket(
            address(this),       // seller: vault delivers tTBILL
            borrower,            // buyer:  borrower delivers USDC
            collateralToReturn,  // bond leg
            totalOwed,           // cash leg
            1 hours              // ticket expiry
        );

        // ── Execute atomic DVP ────────────────────────────────────
        // Leg 1: tTBILL vault    → borrower      (collateral returned)
        // Leg 2: USDC   borrower → lendingPool   (loan + interest paid)
        // If either leg fails → entire tx reverts atomically
        IRepoSettlement(repoSettlement).executeSettlement(ticketId);

        // ── Tell LendingPool to update totalLoaned ────────────────
        ILendingPool(lendingPool).receiveRepayment(pos.loanAmount, interest);

        emit RepoClosed(repoId, borrower, totalOwed);
    }

    // ─── MARGIN CALL: ISSUE ──────────────────────────────────────

    /// @notice MarginEngine calls this when LTV breaches 90%
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

    /// @notice Borrower tops up collateral to clear the margin call
    function meetMarginCall(
        uint256 repoId,
        uint256 additionalCollateral
    ) external nonReentrant {
        RepoPosition storage pos = repos[repoId];

        require(pos.isActive,                              "Repo is not active");
        require(pos.marginCallActive,                      "No margin call active");
        require(block.timestamp <= pos.marginCallDeadline, "Window expired");
        require(pos.borrower == msg.sender,                "Not your repo");
        require(additionalCollateral > 0,                  "Zero collateral");

        require(
            tTBILL.transferFrom(msg.sender, address(this), additionalCollateral),
            "Top-up transfer failed"
        );

        pos.collateralAmount  += additionalCollateral;
        pos.marginCallActive   = false;
        pos.marginCallDeadline = 0;

        emit MarginCallMet(repoId, additionalCollateral);
    }

    // ─── LIQUIDATION ─────────────────────────────────────────────

    /// @notice MarginEngine calls this when LTV hits 95% or margin call expires
    /// @dev    FIX 1: USDC.transfer(lendingPool) added — was missing before
    ///         FIX 2: Uses ILendingPool interface instead of raw .call()
    ///         ⚠️  TODO: tTBILL → USDC swap not yet integrated
    ///                   Currently assumes USDC is available in vault
    ///                   Must integrate Uniswap swap before mainnet
    function liquidate(uint256 repoId)
        external onlyMarginEngine nonReentrant
    {
        RepoPosition storage pos = repos[repoId];
        require(pos.isActive, "Repo is not active");

        // Calculate what borrower owes
        uint256 interest  = RepoMath.repoInterest(
            pos.loanAmount,
            pos.repoRateBps,
            pos.termDays
        );
        uint256 totalOwed = pos.loanAmount + interest;

        // Value collateral at current oracle price
        uint256 bondPrice    = oracle.getLatestPrice();
        uint256 saleProceeds = RepoMath.bondValueInUSDC(
            pos.collateralAmount,
            bondPrice
        );

        // Split proceeds
        (
            uint256 lenderAmount,
            uint256 borrowerSurplus,
            uint256 penalty
        ) = RepoMath.liquidationSplit(
            saleProceeds,
            totalOwed,
            liquidationPenaltyBps
        );

        // ── CEI: Close position BEFORE any transfers ──────────────
        address borrower = pos.borrower;
        pos.isActive     = false;

        // ── Send USDC to LendingPool ──────────────────────────────
        // FIX: This was completely missing in original contract
        require(
            USDC.transfer(lendingPool, lenderAmount),
            "USDC transfer to LendingPool failed"
        );

        // ── Update LendingPool accounting ─────────────────────────
        // FIX: Use interface instead of raw .call() — type safe
        ILendingPool(lendingPool).creditLiquidation(repoId, lenderAmount);

        // ── Return surplus to borrower if any ─────────────────────
        if (borrowerSurplus > 0) {
            require(
                USDC.transfer(borrower, borrowerSurplus),
                "Surplus transfer failed"
            );
        }

        emit Liquidated(
            repoId,
            saleProceeds,
            lenderAmount,
            borrowerSurplus,
            penalty
        );
    }

    // ─── VIEWS ───────────────────────────────────────────────────
    function getRepo(uint256 repoId)
        external view returns (RepoPosition memory)
    {
        return repos[repoId];
    }

    function getBorrowerRepos(address borrower)
        external view returns (uint256[] memory)
    {
        return borrowerRepos[borrower];
    }

    function getCollateralValue(uint256 repoId)
        external view returns (uint256)
    {
        RepoPosition memory pos = repos[repoId];
        uint256 bondPrice = oracle.getLatestPrice();
        return RepoMath.bondValueInUSDC(pos.collateralAmount, bondPrice);
    }

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
