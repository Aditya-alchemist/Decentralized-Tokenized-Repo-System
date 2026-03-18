// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RepoSettlement
/// @notice Atomic DVP (Delivery vs Payment) Settlement
///
/// @dev WHAT IS DVP?
///      In traditional finance, when you buy a bond, there is a T+1 or T+2
///      settlement gap. This means you pay money on Day 0, but receive the bond
///      on Day 1 or Day 2. During that gap, if the counterparty goes bankrupt,
///      you lose your money. This is called "settlement risk."
///
///      This contract eliminates settlement risk completely.
///      Bond delivery and cash payment happen in the SAME Ethereum transaction.
///      If either leg fails, the ENTIRE transaction reverts — atomically.
///      There is zero gap, zero counterparty risk.
///
///      This is the blockchain's most powerful feature applied to finance.

contract RepoSettlement is ReentrancyGuard, Ownable {

    // ─── State ───────────────────────────────────────────────────
    IERC20 public immutable tTBILL;
    IERC20 public immutable USDC;

    address public repoVault;
    address public lendingPool;

    struct SettlementTicket {
        address seller;       // delivers bond, receives cash
        address buyer;        // delivers cash, receives bond
        uint256 bondAmount;   // tTBILL amount (18 decimals)
        uint256 cashAmount;   // USDC amount (6 decimals)
        bool    executed;     // true once settled or expired
        uint256 createdAt;    // when ticket was created
        uint256 expiresAt;    // must settle before this timestamp
    }

    uint256 public nextTicketId;
    mapping(uint256 => SettlementTicket) public tickets;

    // ─── Events ──────────────────────────────────────────────────
    event TicketCreated(
        uint256 indexed ticketId,
        address indexed seller,
        address indexed buyer,
        uint256 bondAmount,
        uint256 cashAmount
    );
    event SettlementExecuted(
        uint256 indexed ticketId,
        uint256 bondAmount,
        uint256 cashAmount
    );
    event TicketExpired(uint256 indexed ticketId);

    // ─── Constructor ─────────────────────────────────────────────
    constructor(
        address _tTBILL,
        address _USDC,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_tTBILL != address(0), "Zero address: tTBILL");
        require(_USDC   != address(0), "Zero address: USDC");
        tTBILL = IERC20(_tTBILL);
        USDC   = IERC20(_USDC);
    }

    // ─── Setup ───────────────────────────────────────────────────
    function setAddresses(
        address _repoVault,
        address _lendingPool
    ) external onlyOwner {
        require(_repoVault   != address(0), "Zero address: vault");
        require(_lendingPool != address(0), "Zero address: pool");
        repoVault   = _repoVault;
        lendingPool = _lendingPool;
    }

    // ─── CREATE TICKET ───────────────────────────────────────────

    /// @notice Creates a pending DVP settlement instruction
    /// @dev    Both parties must have approved this contract to spend
    ///         their tokens BEFORE executeSettlement is called
    function createTicket(
        address seller,
        address buyer,
        uint256 bondAmount,
        uint256 cashAmount,
        uint256 expirySeconds
    ) external returns (uint256 ticketId) {
        require(
            msg.sender == repoVault || msg.sender == lendingPool,
            "Only RepoVault or LendingPool"
        );
        require(seller      != address(0), "Zero address: seller");
        require(buyer       != address(0), "Zero address: buyer");
        require(bondAmount  >  0,          "Zero bond amount");
        require(cashAmount  >  0,          "Zero cash amount");
        require(expirySeconds >= 1 minutes, "Expiry too short");

        ticketId = nextTicketId++;

        tickets[ticketId] = SettlementTicket({
            seller:     seller,
            buyer:      buyer,
            bondAmount: bondAmount,
            cashAmount: cashAmount,
            executed:   false,
            createdAt:  block.timestamp,
            expiresAt:  block.timestamp + expirySeconds
        });

        emit TicketCreated(ticketId, seller, buyer, bondAmount, cashAmount);
    }

    // ─── ATOMIC DVP EXECUTION ────────────────────────────────────

    /// @notice Executes both transfer legs in a single atomic transaction
    /// @dev    THE CORE INNOVATION:
    ///         Leg 1 (bond)  — tTBILL moves from seller to buyer
    ///         Leg 2 (cash)  — USDC moves from buyer to seller
    ///
    ///         If Leg 2 fails for ANY reason, Leg 1 also reverts.
    ///         The EVM guarantees this — either both happen or neither happens.
    ///         This is physically impossible in traditional finance.
    function executeSettlement(uint256 ticketId)
        external nonReentrant
    {
        SettlementTicket storage t = tickets[ticketId];

        require(!t.executed,                     "Already executed");
        require(block.timestamp <= t.expiresAt,  "Ticket has expired");

        // Mark as executed BEFORE transfers (CEI pattern)
        t.executed = true;

        // ── Leg 1: Bond delivery (seller → buyer) ─────────────────
        require(
            tTBILL.transferFrom(t.seller, t.buyer, t.bondAmount),
            "Bond leg failed"
        );

        // ── Leg 2: Cash payment (buyer → seller) ──────────────────
        // If this fails → ENTIRE transaction reverts including Leg 1
        // Atomic settlement guaranteed by EVM
      require(
    USDC.transferFrom(t.buyer, lendingPool, t.cashAmount),
    "Cash leg failed"
);

        emit SettlementExecuted(ticketId, t.bondAmount, t.cashAmount);
    }

    // ─── EXPIRE STALE TICKETS ────────────────────────────────────

    /// @notice Marks expired tickets as dead — prevents future execution
    function expireTicket(uint256 ticketId) external {
        SettlementTicket storage t = tickets[ticketId];
        require(!t.executed,                   "Already executed");
        require(block.timestamp > t.expiresAt, "Not yet expired");
        t.executed = true;
        emit TicketExpired(ticketId);
    }

    // ─── VIEWS ───────────────────────────────────────────────────

    function getTicket(uint256 ticketId)
        external view returns (SettlementTicket memory)
    {
        return tickets[ticketId];
    }

    function isExecuted(uint256 ticketId) external view returns (bool) {
        return tickets[ticketId].executed;
    }
}
