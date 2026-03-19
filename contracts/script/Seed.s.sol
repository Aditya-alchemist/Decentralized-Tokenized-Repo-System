// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/StdJson.sol";

import "../src/tokens/MockTBill.sol";
import "../src/tokens/RepoPoolToken.sol";
import "../src/oracle/BondPriceOracle.sol";
import "../src/core/LendingPool.sol";
import "../src/core/RepoVault.sol";

contract Seed is Script {
    using stdJson for string;

    // ─── Seed amounts ─────────────────────────────────────────────
    uint256 constant LENDER_USDC       = 100_000 * 1e6;  // $100,000 USDC
    uint256 constant LENDER_DEPOSIT    =  50_000 * 1e6;  // $50,000 into pool
    uint256 constant BORROWER_TBILL    =     100 * 1e18; // 100 tTBILL bonds
    uint256 constant BORROW_COLLATERAL =      10 * 1e18; // 10 tTBILL collateral
    uint256 constant BORROW_LOAN       =   5_000 * 1e6;  // $5,000 USDC loan (safe under LTV)

    function run() external {

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("=================================================");
        console.log("Seeding Repo Protocol");
        console.log("Deployer:", deployer);
        console.log("=================================================");

        // ─── Load addresses ───────────────────────────────────────
        string memory json = vm.readFile("deployments/addresses.json");

        address tTBILLAddr         = json.readAddress(".MockTBill");
        address USDCAddr           = json.readAddress(".MockUSDC");
        address lendingPoolAddr    = json.readAddress(".LendingPool");
        address repoVaultAddr      = json.readAddress(".RepoVault");
        address repoSettlementAddr = json.readAddress(".RepoSettlement");
        address oracleAddr         = json.readAddress(".BondPriceOracle");

        MockTBill       tTBILL      = MockTBill(tTBILLAddr);
        MockTBill       USDC        = MockTBill(USDCAddr);
        LendingPool     lendingPool = LendingPool(lendingPoolAddr);
        RepoVault       repoVault   = RepoVault(repoVaultAddr);
        BondPriceOracle oracle      = BondPriceOracle(oracleAddr);

        console.log("Loaded from addresses.json");
        console.log("MockTBill:      ", tTBILLAddr);
        console.log("MockUSDC:       ", USDCAddr);
        console.log("LendingPool:    ", lendingPoolAddr);
        console.log("RepoVault:      ", repoVaultAddr);
        console.log("BondPriceOracle:", oracleAddr);

        vm.startBroadcast(deployerKey);

        // ─── Step 0a: Fix oracle price ────────────────────────────
        // $980.00 = 980 × 1e8 = 98_000_000_000
        // collateralValue = (10e18 × 98_000_000_000) / 1e8 / 1e12
        //                 = $9,800 USDC  → maxLoan ~$9,310 USDC ✅
        oracle.updatePrice(98_000_000_000);
        console.log("Oracle price set to $980.00");

        // ─── Step 0b: KYC whitelist deployer + protocol contracts ─
        // Only needed if contracts were deployed without KYC step
        // Safe to call even if already granted (no-op if role exists)
        tTBILL.grantKYC(deployer);
        tTBILL.grantKYC(lendingPoolAddr);
        tTBILL.grantKYC(repoVaultAddr);
        tTBILL.grantKYC(repoSettlementAddr);

        USDC.grantKYC(deployer);
        USDC.grantKYC(lendingPoolAddr);
        USDC.grantKYC(repoVaultAddr);
        USDC.grantKYC(repoSettlementAddr);

        console.log("KYC granted to deployer + all protocol contracts");

        // ─── Step 1: Mint USDC to deployer (lender) ───────────────
        USDC.mint(deployer, LENDER_USDC);
        console.log("Minted $100,000 USDC to deployer");

        // ─── Step 2: Mint tTBILL to deployer (borrower) ───────────
        tTBILL.mint(deployer, BORROWER_TBILL);
        console.log("Minted 100 tTBILL to deployer");

        // ─── Step 3: Lender deposits USDC into pool ───────────────
        USDC.approve(lendingPoolAddr, LENDER_DEPOSIT);
        lendingPool.deposit(LENDER_DEPOSIT);
        console.log("Deposited $50,000 USDC into LendingPool");

        // ─── Step 4: Borrower opens repo loan ─────────────────────
        // collateralValue = 10 tTBILL × $980 = $9,800
        // maxLoan (5% haircut) = $9,310
        // BORROW_LOAN = $5,000 — safely within LTV ✅
        tTBILL.approve(repoVaultAddr, BORROW_COLLATERAL);
        uint256 repoId = lendingPool.requestRepo(
            BORROW_COLLATERAL,
            BORROW_LOAN
        );
        console.log("Borrower opened repo ID:", repoId);

        vm.stopBroadcast();

        // ─── Step 5: Print full system state ──────────────────────
        console.log("\n========== SYSTEM STATE ==========");

        console.log("-- Oracle --");
        console.log("bondPrice:         ", oracle.getLatestPrice(), "(8 dec, $980.00)");

        console.log("\n-- LendingPool --");
        console.log("totalPoolValue:    ", lendingPool.totalPoolValue()     / 1e6, "USDC");
        console.log("availableLiquidity:", lendingPool.availableLiquidity() / 1e6, "USDC");
        console.log("totalLoaned:       ", lendingPool.totalLoaned()        / 1e6, "USDC");
        console.log("sharePrice:        ", lendingPool.sharePrice(),              "(1e6=$1.00)");

        (uint256 shares, uint256 usdcVal) = lendingPool.getLenderBalance(deployer);
        console.log("\n-- Lender (deployer) --");
        console.log("rpUSDC shares:     ", shares  / 1e6);
        console.log("USDC value:        ", usdcVal / 1e6, "USDC");

        console.log("\n-- Repo Position --");
        console.log("repoId:            ", repoId);
        console.log("totalOwed:         ", repoVault.getTotalOwed(repoId)       / 1e6, "USDC");
        console.log("collateralValue:   ", repoVault.getCollateralValue(repoId) / 1e6, "USDC");
        console.log("isPositionSafe:    ", repoVault.isPositionSafe(repoId));

        console.log("\n===================================");
        console.log("SEED COMPLETE");
        console.log("===================================");
    }
}
