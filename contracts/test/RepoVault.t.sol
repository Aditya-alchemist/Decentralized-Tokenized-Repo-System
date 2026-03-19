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

contract RepoVaultTest is Test {

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

        USDC.mint(lender,    50_000 * 1e6);
        tTBILL.mint(borrower,  100 * 1e18);

        // Fund pool
        vm.startPrank(lender);
        USDC.approve(address(lendingPool), 50_000 * 1e6);
        lendingPool.deposit(50_000 * 1e6);
        vm.stopPrank();
    }

    // ─── Helper ───────────────────────────────────────────────────
    function _openRepo() internal returns (uint256 repoId) {
        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        repoId = lendingPool.requestRepo(COLLATERAL, LOAN_AMOUNT);
        vm.stopPrank();
    }

    // ─── OPEN REPO ────────────────────────────────────────────────

    function test_openRepo_locksCollateral() public {
        uint256 balBefore = tTBILL.balanceOf(borrower);
        _openRepo();
        assertEq(tTBILL.balanceOf(borrower), balBefore - COLLATERAL);
        assertEq(tTBILL.balanceOf(address(repoVault)), COLLATERAL);
    }

    function test_openRepo_recordsPosition() public {
        uint256 repoId = _openRepo();
        RepoVault.RepoPosition memory pos = repoVault.getRepo(repoId);

        assertEq(pos.borrower,         borrower);
        assertEq(pos.collateralAmount, COLLATERAL);
        assertEq(pos.loanAmount,       LOAN_AMOUNT);
        assertTrue(pos.isActive);
        assertFalse(pos.marginCallActive);
    }

    function test_openRepo_revertsLoanExceedsLTV() public {
        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), COLLATERAL);
        // $9,500 exceeds max LTV of ~$9,310
        vm.expectRevert("Loan exceeds max LTV");
        lendingPool.requestRepo(COLLATERAL, 9_500 * 1e6);
        vm.stopPrank();
    }

    // ─── REPAY REPO ───────────────────────────────────────────────

    function test_repayRepo_returnsCollateral() public {
        uint256 repoId    = _openRepo();
        uint256 totalOwed = repoVault.getTotalOwed(repoId);

        // Give borrower extra USDC for interest
        USDC.mint(borrower, 100 * 1e6);
        USDC.grantKYC(borrower);

        vm.startPrank(borrower);
        USDC.approve(address(repoSettlement), totalOwed);
        repoVault.repayRepo(repoId);
        vm.stopPrank();

        // Collateral returned
        assertEq(tTBILL.balanceOf(borrower), 100 * 1e18);

        // Position closed
        RepoVault.RepoPosition memory pos = repoVault.getRepo(repoId);
        assertFalse(pos.isActive);
    }

    function test_repayRepo_revertsNotBorrower() public {
        uint256 repoId = _openRepo();
        vm.startPrank(lender);
        vm.expectRevert("You did not open this repo");
        repoVault.repayRepo(repoId);
        vm.stopPrank();
    }

    function test_repayRepo_revertsAlreadyClosed() public {
        uint256 repoId    = _openRepo();
        uint256 totalOwed = repoVault.getTotalOwed(repoId);
        USDC.mint(borrower, 100 * 1e6);

        vm.startPrank(borrower);
        USDC.approve(address(repoSettlement), totalOwed);
        repoVault.repayRepo(repoId);

        // Try to repay again
        vm.expectRevert("Repo is not active");
        repoVault.repayRepo(repoId);
        vm.stopPrank();
    }

    // ─── COLLATERAL VALUE ─────────────────────────────────────────

    function test_collateralValue_correctAtCurrentPrice() public {
        uint256 repoId = _openRepo();
        // 10 tTBILL × $980 = $9,800
        assertEq(repoVault.getCollateralValue(repoId), 9_800 * 1e6);
    }

    function test_collateralValue_dropsWithPrice() public {
        uint256 repoId = _openRepo();
        // Price drops to $700
        oracle.updatePrice(70_000_000_000);
        // 10 × $700 = $7,000
        assertEq(repoVault.getCollateralValue(repoId), 7_000 * 1e6);
    }

    // ─── POSITION SAFETY ─────────────────────────────────────────

    function test_isPositionSafe_trueAtNormalPrice() public {
        uint256 repoId = _openRepo();
        assertTrue(repoVault.isPositionSafe(repoId));
    }

    function test_isPositionSafe_falseWhenUndercollateralised() public {
        uint256 repoId = _openRepo();
        // Crash price to $400 — $4,000 collateral vs $5,000 loan
        oracle.updatePrice(40_000_000_000);
        assertFalse(repoVault.isPositionSafe(repoId));
    }
}
