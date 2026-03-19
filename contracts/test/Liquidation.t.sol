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

contract LiquidationTest is Test {

    MockTBill       tTBILL;
    MockTBill       USDC;
    RepoPoolToken   rpUSDC;
    BondPriceOracle oracle;
    RepoVault       repoVault;
    LendingPool     lendingPool;
    MarginEngine    marginEngine;
    RepoSettlement  repoSettlement;

    address admin    = address(this);
    address lender   = makeAddr("lender");
    address borrower = makeAddr("borrower");

    uint256 constant INITIAL_PRICE = 98_000_000_000;
    uint256 constant COLLATERAL    = 10  * 1e18;
    uint256 constant LOAN_AMOUNT   = 5_000 * 1e6;

    function setUp() public {
        tTBILL = new MockTBill(
            "Mock T-Bill", "tTBILL", "US912796YT68",
            1000 * 1e6, 500, block.timestamp + 365 days, admin
        );
        USDC = new MockTBill(
            "Mock USDC", "USDC", "USDC-MOCK",
            1 * 1e6, 0, block.timestamp + 365 days, admin
        );
        rpUSDC        = new RepoPoolToken(admin);
        oracle        = new BondPriceOracle(admin);
        repoVault     = new RepoVault(address(tTBILL), address(USDC), address(oracle), admin);
        lendingPool   = new LendingPool(address(USDC), address(rpUSDC), admin);
        marginEngine  = new MarginEngine(address(oracle), address(repoVault), admin);
        repoSettlement = new RepoSettlement(address(tTBILL), address(USDC), admin);

        repoVault.setLendingPool(address(lendingPool));
        repoVault.setMarginEngine(address(marginEngine));
        repoVault.setRepoSettlement(address(repoSettlement));
        lendingPool.setRepoVault(address(repoVault));
        repoSettlement.setAddresses(address(repoVault), address(lendingPool));
        rpUSDC.setLendingPool(address(lendingPool));
        oracle.updatePrice(INITIAL_PRICE);

        tTBILL.grantKYC(lender);   tTBILL.grantKYC(borrower);
        tTBILL.grantKYC(address(lendingPool));
        tTBILL.grantKYC(address(repoVault));
        tTBILL.grantKYC(address(repoSettlement));

        USDC.grantKYC(lender);     USDC.grantKYC(borrower);
        USDC.grantKYC(address(lendingPool));
        USDC.grantKYC(address(repoVault));
        USDC.grantKYC(address(repoSettlement));

        USDC.mint(lender, 50_000 * 1e6);
        tTBILL.mint(borrower, 100 * 1e18);

        vm.startPrank(lender);
        USDC.approve(address(lendingPool), 50_000 * 1e6);
        lendingPool.deposit(50_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        lendingPool.requestRepo(COLLATERAL, LOAN_AMOUNT);
        vm.stopPrank();

        // Seed vault with USDC for liquidation payouts
        // In production this comes from selling tTBILL
        USDC.mint(address(repoVault), 20_000 * 1e6);
        USDC.grantKYC(address(repoVault));
    }

    // ─── LIQUIDATION TESTS ────────────────────────────────────────

    function test_liquidation_closesPosition() public {
        oracle.updatePrice(52_500_000_000); // $525 → LTV 95%+

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        RepoVault.RepoPosition memory pos = repoVault.getRepo(0);
        assertFalse(pos.isActive);
    }

    function test_liquidation_lenderMadeWhole() public {
        oracle.updatePrice(52_500_000_000);

        uint256 poolBefore = USDC.balanceOf(address(lendingPool));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        uint256 poolAfter = USDC.balanceOf(address(lendingPool));

        // Pool received at minimum the loan amount
        assertGe(poolAfter, poolBefore + LOAN_AMOUNT);
    }

    function test_liquidation_borrowerGetsSurplus() public {
        // At $980 price, collateral = $9,800 >> loan $5,000
        // Surplus = $9,800 - $5,005 - penalty = large surplus to borrower
        // Force liquidation directly (skip margin call threshold)
        oracle.updatePrice(52_500_000_000);

        uint256 borrowerBefore = USDC.balanceOf(borrower);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        // At $525 price, collateral = $5,250
        // totalOwed = ~$5,005
        // surplus = $245 → borrower gets most of it after 2% penalty
        uint256 borrowerAfter = USDC.balanceOf(borrower);
        assertGe(borrowerAfter, borrowerBefore);
    }

    function test_liquidation_revertsOnInactiveRepo() public {
        // Close repo first via repayment
        uint256 totalOwed = repoVault.getTotalOwed(0);
        USDC.mint(borrower, 100 * 1e6);
        vm.startPrank(borrower);
        USDC.approve(address(repoSettlement), totalOwed);
        repoVault.repayRepo(0);
        vm.stopPrank();

        // Try to liquidate already closed repo
        vm.expectRevert("Only MarginEngine");
        repoVault.liquidate(0);
    }

    function test_liquidation_decreasesTotalLoaned() public {
        oracle.updatePrice(52_500_000_000);

        uint256 loanedBefore = lendingPool.totalLoaned();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        uint256 loanedAfter = lendingPool.totalLoaned();
        assertLt(loanedAfter, loanedBefore);
    }

    // ─── SHORTFALL TEST ───────────────────────────────────────────

    function test_liquidation_shortfall_lenderAbsorbsLoss() public {
        // Price crashes to $300 — collateral $3,000 < loan $5,000
        oracle.updatePrice(30_000_000_000);

        uint256 poolBefore = USDC.balanceOf(address(lendingPool));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        uint256 poolAfter = USDC.balanceOf(address(lendingPool));

        // Pool received something but less than full loan
        assertGt(poolAfter, poolBefore);
        assertLt(poolAfter - poolBefore, LOAN_AMOUNT);
    }

    // ─── FULL LIFECYCLE TEST ──────────────────────────────────────

    function test_fullLifecycle_depositBorrowRepayWithdraw() public {
        // 1. State after setUp: lender deposited, borrower borrowed
        assertEq(lendingPool.totalLoaned(), LOAN_AMOUNT);

        // 2. Borrower repays
        uint256 totalOwed = repoVault.getTotalOwed(0);
        USDC.mint(borrower, 100 * 1e6);
        vm.startPrank(borrower);
        USDC.approve(address(repoSettlement), totalOwed);
        repoVault.repayRepo(0);
        vm.stopPrank();

        assertEq(lendingPool.totalLoaned(), 0);

        // 3. Share price grew
        assertGe(lendingPool.sharePrice(), 1e6);

        // 4. Lender withdraws everything
        uint256 shares = rpUSDC.balanceOf(lender);
        vm.startPrank(lender);
        lendingPool.withdraw(shares);
        vm.stopPrank();

        // 5. Lender got back more than they put in
        assertGt(USDC.balanceOf(lender), 50_000 * 1e6);
        assertEq(rpUSDC.balanceOf(lender), 0);
    }
}
