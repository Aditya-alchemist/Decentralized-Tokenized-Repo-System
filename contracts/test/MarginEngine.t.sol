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

contract MarginEngineTest is Test {

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
    }

    // ─── LTV CHECKS ───────────────────────────────────────────────

    function test_checkRepo_healthyPosition_noAction() public {
        // At $980 price, LTV = 5000/9800 = 51% — safe
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        // Should not revert — position is healthy
        marginEngine.checkRepos(ids);
        RepoVault.RepoPosition memory pos = repoVault.getRepo(0);
        assertFalse(pos.marginCallActive);
    }

    function test_checkRepo_issuesMarginCall_at90LTV() public {
        // LTV = 90% → loan $5,000 / collateral must be ~$5,556
        // price needs to drop to: $5,000 / (10 × price) = 90%
        // price = $5,000 / (10 × 0.9) = $555.56
        // use $560 to be just above 90%
        oracle.updatePrice(56_000_000_000); // $560 → LTV = 5000/5600 = 89.3%
        oracle.updatePrice(55_500_000_000); // $555 → LTV = 5000/5550 = 90.1% ← margin call

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        RepoVault.RepoPosition memory pos = repoVault.getRepo(0);
        assertTrue(pos.marginCallActive);
        assertGt(pos.marginCallDeadline, block.timestamp);
    }

    function test_checkRepo_liquidates_at95LTV() public {
        // LTV = 95% → collateral = $5,000 / 0.95 = $5,263
        // 10 tTBILL × price = $5,263 → price = $526.30
        oracle.updatePrice(52_500_000_000); // $525 → LTV = 5000/5250 = 95.2%

        // Liquidation currently pays lenders out of vault USDC balance.
        USDC.mint(address(repoVault), 10_000 * 1e6);

        uint256 poolBefore = lendingPool.totalPoolValue();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        RepoVault.RepoPosition memory pos = repoVault.getRepo(0);
        assertFalse(pos.isActive); // liquidated
        assertGt(lendingPool.totalPoolValue(), 0);
        // Pool should be whole or better after liquidation (interest/penalty may increase value).
        assertGe(lendingPool.totalPoolValue(), poolBefore);
    }

    // ─── MARGIN CALL: MEET ────────────────────────────────────────

    function test_meetMarginCall_clearsMarginCall() public {
        oracle.updatePrice(55_500_000_000);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        // Borrower tops up 2 tTBILL
        uint256 topUp = 2 * 1e18;
        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), topUp);
        repoVault.meetMarginCall(0, topUp);
        vm.stopPrank();

        RepoVault.RepoPosition memory pos = repoVault.getRepo(0);
        assertFalse(pos.marginCallActive);
        assertEq(pos.collateralAmount, COLLATERAL + topUp);
    }

    function test_meetMarginCall_revertsAfterDeadline() public {
        oracle.updatePrice(55_500_000_000);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        // Fast forward past 4 hour deadline
        vm.warp(block.timestamp + 5 hours);

        vm.startPrank(borrower);
        tTBILL.approve(address(repoVault), 2 * 1e18);
        vm.expectRevert("Window expired");
        repoVault.meetMarginCall(0, 2 * 1e18);
        vm.stopPrank();
    }

    function test_expiredMarginCall_triggersLiquidation() public {
        oracle.updatePrice(55_500_000_000);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        marginEngine.checkRepos(ids);

        // Deadline passes — borrower does nothing
        vm.warp(block.timestamp + 5 hours);

        // Oracle has a 2h stale threshold, so refresh to keep safety checks active.
        oracle.updatePrice(55_500_000_000);

        // Liquidation currently pays lenders out of vault USDC balance.
        USDC.mint(address(repoVault), 10_000 * 1e6);

        // Keeper calls checkRepos again → triggers liquidation
        marginEngine.checkRepos(ids);

        RepoVault.RepoPosition memory pos = repoVault.getRepo(0);
        assertFalse(pos.isActive);
    }

    // ─── ACCESS CONTROL ───────────────────────────────────────────

    function test_issueMarginCall_revertsNotMarginEngine() public {
        vm.startPrank(lender);
        vm.expectRevert("Only MarginEngine");
        repoVault.issueMarginCall(0);
        vm.stopPrank();
    }

    function test_liquidate_revertsNotMarginEngine() public {
        vm.startPrank(lender);
        vm.expectRevert("Only MarginEngine");
        repoVault.liquidate(0);
        vm.stopPrank();
    }
}
