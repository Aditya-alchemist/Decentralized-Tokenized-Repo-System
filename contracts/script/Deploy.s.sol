// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/tokens/MockTBill.sol";
import "../src/tokens/RepoPoolToken.sol";
import "../src/oracle/BondPriceOracle.sol";
import "../src/core/RepoVault.sol";
import "../src/core/LendingPool.sol";
import "../src/core/MarginEngine.sol";
import "../src/core/RepoSettlement.sol";

contract Deploy is Script {

    function run() external {

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("Chain:   ", block.chainid);
        console.log("=================================================");

        vm.startBroadcast(deployerKey);

        // ─── 1. MockTBill ─────────────────────────────────────────
        MockTBill tTBILL = new MockTBill(
            "Mock T-Bill",
            "tTBILL",
            "US912796YT68",
            1000 * 1e6,
            500,
            block.timestamp + 365 days,
            deployer
        );
        console.log("MockTBill:      ", address(tTBILL));

        // ─── 2. MockUSDC ──────────────────────────────────────────
        MockTBill USDC = new MockTBill(
            "Mock USDC",
            "USDC",
            "USDC-MOCK",
            1 * 1e6,
            0,
            block.timestamp + 365 days,
            deployer
        );
        console.log("MockUSDC:       ", address(USDC));

        // ─── 3. RepoPoolToken ─────────────────────────────────────
        RepoPoolToken rpUSDC = new RepoPoolToken(deployer);
        console.log("RepoPoolToken:  ", address(rpUSDC));

        // ─── 4. BondPriceOracle ───────────────────────────────────
        BondPriceOracle oracle = new BondPriceOracle(deployer);
        console.log("BondPriceOracle:", address(oracle));

        // ─── 5. RepoVault ─────────────────────────────────────────
        RepoVault repoVault = new RepoVault(
            address(tTBILL),
            address(USDC),
            address(oracle),
            deployer
        );
        console.log("RepoVault:      ", address(repoVault));

        // ─── 6. LendingPool ───────────────────────────────────────
        LendingPool lendingPool = new LendingPool(
            address(USDC),
            address(rpUSDC),
            deployer
        );
        console.log("LendingPool:    ", address(lendingPool));

        // ─── 7. MarginEngine ──────────────────────────────────────
        MarginEngine marginEngine = new MarginEngine(
            address(oracle),
            address(repoVault),
            deployer
        );
        console.log("MarginEngine:   ", address(marginEngine));

        // ─── 8. RepoSettlement ────────────────────────────────────
        RepoSettlement repoSettlement = new RepoSettlement(
            address(tTBILL),
            address(USDC),
            deployer
        );
        console.log("RepoSettlement: ", address(repoSettlement));

        // ─── 9. Wire contracts ────────────────────────────────────
        console.log("Wiring...");

        repoVault.setLendingPool(address(lendingPool));
        repoVault.setMarginEngine(address(marginEngine));
        repoVault.setRepoSettlement(address(repoSettlement));
        console.log("RepoVault wired");

        lendingPool.setRepoVault(address(repoVault));
        console.log("LendingPool wired");

        repoSettlement.setAddresses(address(repoVault), address(lendingPool));
        console.log("RepoSettlement wired");

        // ─── 10. Set initial oracle price ─────────────────────────
        // FIX: $980.00 in 8 decimals = 980 × 1e8 = 98_000_000_000
        // Previous value 98_000_000 = only $0.98 — caused LTV failures
        oracle.updatePrice(98_000_000_000);
        console.log("Oracle price set to $980.00 (98_000_000_000)");

        // ─── 11. Grant rpUSDC minter to LendingPool ───────────────
        rpUSDC.setLendingPool(address(lendingPool));
        console.log("rpUSDC minter set to LendingPool");

        // ─── 12. KYC whitelist all protocol contracts ─────────────
        // MockTBill enforces KYC on every transfer sender + recipient
        // All core contracts must be whitelisted or transfers revert
        tTBILL.grantKYC(address(lendingPool));
        tTBILL.grantKYC(address(repoVault));
        tTBILL.grantKYC(address(repoSettlement));

        USDC.grantKYC(address(lendingPool));
        USDC.grantKYC(address(repoVault));
        USDC.grantKYC(address(repoSettlement));

        console.log("KYC granted to LendingPool, RepoVault, RepoSettlement");

        vm.stopBroadcast();

        // ─── 13. Write addresses.json ─────────────────────────────
        string memory json = string(abi.encodePacked(
            '{\n',
            '  "MockTBill":       "', vm.toString(address(tTBILL)),         '",\n',
            '  "MockUSDC":        "', vm.toString(address(USDC)),           '",\n',
            '  "RepoPoolToken":   "', vm.toString(address(rpUSDC)),         '",\n',
            '  "BondPriceOracle": "', vm.toString(address(oracle)),         '",\n',
            '  "RepoVault":       "', vm.toString(address(repoVault)),      '",\n',
            '  "LendingPool":     "', vm.toString(address(lendingPool)),    '",\n',
            '  "MarginEngine":    "', vm.toString(address(marginEngine)),   '",\n',
            '  "RepoSettlement":  "', vm.toString(address(repoSettlement)), '"\n',
            '}'
        ));

        vm.writeFile("deployments/addresses.json", json);

        console.log("=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("addresses.json written to deployments/");
        console.log("=================================================");
    }
}
