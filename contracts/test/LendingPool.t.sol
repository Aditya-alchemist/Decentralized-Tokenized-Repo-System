// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/tokens/MockTBill.sol";
import "../src/tokens/RepoPoolToken.sol";
import "../src/oracle/BondPriceOracle.sol";
import "../src/core/RepoVault.sol";
import "../src/core/LendingPool.sol";
import "../src/core/MarginEngine.sol";
import "../src/core/RepoSettlement.sol";

contract LendingPoolTest is Test {

    // ─── Contracts ────────────────────────────────────────────────
    MockTBill       tTBILL;
    MockTBill       USDC;
    RepoPoolToken   rpUSDC;
    BondPriceOracle oracle;
    RepoVault       repoVault;
    LendingPool     lendingPool;
    MarginEngine    marginEngine;
    RepoSettlement  repoSettlement;

    // ─── Actors ───────────────────────────────────────────────────
    address admin    = address(this);
    address lender   = makeAddr("lender");
    address borrower = makeAddr("borrower");

    // ─── Constants ────────────────────────────────────────────────
    uint256 constant INITIAL_PRICE  = 98_000_000_000; // $980.00 (8 decimals)
    uint256 constant DEPOSIT_AMOUNT = 50_000 * 1e6;   // $50,000 USDC
    uint256 constant LOAN_AMOUNT    =  5_000 * 1e6;   // $5,000 USDC
    uint256 constant COLLATERAL     =     10 * 1e18;  // 10 tTBILL

    function setUp() public {

        // ── Deploy tokens ─────────────────────────────────────────
        tTBILL = new MockTBill(
            "Mock T-Bill", "tTBILL", "US912796YT68",
            1000 * 1e6, 500,
            block.timestamp + 365 days, admin
        );
        USDC = new MockTBill(
            "Mock USDC", "USDC", "USDC-MOCK",
            1 * 1e6, 0,
            block.timestamp + 365 days, admin
        );
        rpUSDC = new RepoPoolToken(admin);

        // ── Deploy oracle + core ──────────────────────────────────
        oracle        = new BondPriceOracle(admin);
        repoVault     = new RepoVault(address(tTBILL), address(USDC), address(oracle), admin);
        lendingPool   = new LendingPool(address(USDC), address(rpUSDC), admin);
        marginEngine  = new MarginEngine(address(oracle), address(repoVault), admin);
        repoSettlement = new RepoSettlement(address(tTBILL), address(USDC), admin);

        // ── Wire contracts ────────────────────────────────────────
        repoVault.setLendingPool(address(lendingPool));
        repoVault.setMarginEngine(address(marginEngine));
        repoVault.setRepoSettlement(address(repoSettlement));
        lendingPool.setRepoVault(address(repoVault));
        repoSettlement.setAddresses(address(repoVault), address(lendingPool));
        rpUSDC.setLendingPool(address(lendingPool));

        // ── Oracle price ──────────────────────────────────────────
        oracle.updatePrice(INITIAL_PRICE);

        // ── KYC ───────────────────────────────────────────────────
        tTBILL.grantKYC(lender);
        tTBILL.grantKYC(borrower);
        tTBILL.grantKYC(address(lendingPool));
        tTBILL.grantKYC(address(repoVault));
        tTBILL.grantKYC(address(repoSettlement));

        USDC.grantKYC(lender);
        USDC.grantKYC(borrower);
        USDC.grantKYC(address(lendingPool));
        USDC.grantKYC(address(repoVault));
        USDC.grantKYC(address(repoSettlement));

        // ── Fund wallets ──────────────────────────────────────────
        USDC.mint(lender,    100_000 * 1e6);
        USDC.mint(borrower,   10_000 * 1e6);
        tTBILL.mint(borrower,    100 * 1e18);
    }

    // ─── DEPOSIT TESTS ───────────────────────────────────────────

    function test_deposit_firstDepositor_gets1to1Shares() public {
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), DEPOSIT_AMOUNT);
        lendingPool.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(rpUSDC.balanceOf(lender), DEPOSIT_AMOUNT);
        assertEq(lendingPool.totalPoolValue(), DEPOSIT_AMOUNT);
    }

    function test_deposit_secondDepositor_getsCorrectShares() public {
        // First deposit
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), DEPOSIT_AMOUNT);
        lendingPool.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Second depositor
        address lender2 = makeAddr("lender2");
        USDC.grantKYC(lender2);
        tTBILL.grantKYC(lender2);
        USDC.mint(lender2, 100_000 * 1e6);
        uint256 secondDeposit = 25_000 * 1e6;

        vm.startPrank(lender2);
        USDC.approve(address(lendingPool), secondDeposit);
        lendingPool.deposit(secondDeposit);
        vm.stopPrank();

        // At 1:1 sharePrice, second depositor should get same ratio
        assertEq(rpUSDC.balanceOf(lender2), secondDeposit);
        assertEq(lendingPool.totalPoolValue(), DEPOSIT_AMOUNT + secondDeposit);
    }

    function test_deposit_revertsOnZero() public {
        vm.startPrank(lender);
        vm.expectRevert("Cannot deposit zero");
        lendingPool.deposit(0);
        vm.stopPrank();
    }

    // ─── WITHDRAW TESTS ──────────────────────────────────────────

    function test_withdraw_fullAmount_returnsCorrectUSDC() public {
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), DEPOSIT_AMOUNT);
        lendingPool.deposit(DEPOSIT_AMOUNT);

        uint256 shares = rpUSDC.balanceOf(lender);
        lendingPool.withdraw(shares);
        vm.stopPrank();

        assertEq(rpUSDC.balanceOf(lender), 0);
        assertEq(USDC.balanceOf(lender), 100_000 * 1e6); // full balance restored
    }

    function test_withdraw_revertsOnZero() public {
        vm.startPrank(lender);
        vm.expectRevert("Cannot withdraw zero");
        lendingPool.withdraw(0);
        vm.stopPrank();
    }

    function test_withdraw_revertsInsufficientShares() public {
        vm.startPrank(lender);
        vm.expectRevert("Insufficient rpUSDC");
        lendingPool.withdraw(1000 * 1e6);
        vm.stopPrank();
    }

    // ─── REQUEST REPO TESTS ──────────────────────────────────────

    function test_requestRepo_success() public {
        // Lender deposits first
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), DEPOSIT_AMOUNT);
        lendingPool.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Borrower opens repo
        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        uint256 repoId = lendingPool.requestRepo(COLLATERAL, LOAN_AMOUNT);
        vm.stopPrank();

        assertEq(repoId, 0);
        assertEq(lendingPool.totalLoaned(), LOAN_AMOUNT);
        assertEq(USDC.balanceOf(borrower), 10_000 * 1e6 + LOAN_AMOUNT);
    }

    function test_requestRepo_revertsExceedsLiquidity() public {
        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        vm.expectRevert("Insufficient liquidity");
        lendingPool.requestRepo(COLLATERAL, LOAN_AMOUNT);
        vm.stopPrank();
    }

    // ─── SHARE PRICE TESTS ───────────────────────────────────────

    function test_sharePrice_growsAfterInterestRepayment() public {
        // Setup: lender deposits, borrower borrows
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), DEPOSIT_AMOUNT);
        lendingPool.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        lendingPool.requestRepo(COLLATERAL, LOAN_AMOUNT);
        vm.stopPrank();

        uint256 priceBeforeRepay = lendingPool.sharePrice();

        // Borrower repays
        uint256 totalOwed = repoVault.getTotalOwed(0);
        vm.startPrank(borrower);
        USDC.approve(address(repoSettlement), totalOwed);
        tTBILL.approve(address(repoSettlement), COLLATERAL);
        repoVault.repayRepo(0);
        vm.stopPrank();

        uint256 priceAfterRepay = lendingPool.sharePrice();

        // Share price should be higher after interest paid
        assertGt(priceAfterRepay, priceBeforeRepay);
    }

    // ─── POOL VALUE TESTS ─────────────────────────────────────────

    function test_totalPoolValue_includesLoanedAmount() public {
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), DEPOSIT_AMOUNT);
        lendingPool.deposit(DEPOSIT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        lendingPool.requestRepo(COLLATERAL, LOAN_AMOUNT);
        vm.stopPrank();

        // totalPoolValue = balance + loaned = $45,000 + $5,000 = $50,000
        assertEq(lendingPool.totalPoolValue(), DEPOSIT_AMOUNT);
        assertEq(lendingPool.availableLiquidity(), DEPOSIT_AMOUNT - LOAN_AMOUNT);
    }
}
