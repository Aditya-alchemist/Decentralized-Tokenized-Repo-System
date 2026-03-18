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
        // constructor(name, symbol, isin, faceValue, couponRateBps, maturityDate, admin)
        MockTBill tTBILL = new MockTBill(
            "Mock T-Bill",        // name
            "tTBILL",             // symbol
            "US912796YT68",       // isin (example)
            1000 * 1e6,           // faceValue $1000 (6 decimals)
            500,                  // couponRateBps 5%
            block.timestamp + 365 days, // maturityDate 1 year from now
            deployer              // admin
        );
        console.log("MockTBill:      ", address(tTBILL));

        // ─── 2. MockUSDC ──────────────────────────────────────────
        // Reuse MockTBill contract as mock USDC
        MockTBill USDC = new MockTBill(
            "Mock USDC",          // name
            "USDC",               // symbol
            "USDC-MOCK",          // isin placeholder
            1 * 1e6,              // faceValue $1
            0,                    // couponRateBps 0%
            block.timestamp + 365 days, // maturityDate
            deployer              // admin
        );
        console.log("MockUSDC:       ", address(USDC));

        // ─── 3. RepoPoolToken ─────────────────────────────────────
        // constructor(address _initialOwner)
        RepoPoolToken rpUSDC = new RepoPoolToken(deployer);
        console.log("RepoPoolToken:  ", address(rpUSDC));

        // ─── 4. BondPriceOracle ───────────────────────────────────
        // constructor(address initialOwner)
        // keeper bot = deployer for now, update later to keeper wallet
        BondPriceOracle oracle = new BondPriceOracle(deployer);
        console.log("BondPriceOracle:", address(oracle));

        // ─── 5. RepoVault ─────────────────────────────────────────
        // constructor(address _tTBILL, address _USDC, address _oracle, address _initialOwner)
        RepoVault repoVault = new RepoVault(
            address(tTBILL),
            address(USDC),
            address(oracle),
            deployer
        );
        console.log("RepoVault:      ", address(repoVault));

        // ─── 6. LendingPool ───────────────────────────────────────
        // constructor(address _USDC, address _rpUSDC, address _initialOwner)
        LendingPool lendingPool = new LendingPool(
            address(USDC),
            address(rpUSDC),
            deployer
        );
        console.log("LendingPool:    ", address(lendingPool));

        // ─── 7. MarginEngine ──────────────────────────────────────
        // constructor(address _oracle, address _vault, address _initialOwner)
        MarginEngine marginEngine = new MarginEngine(
            address(oracle),
            address(repoVault),
            deployer
        );
        console.log("MarginEngine:   ", address(marginEngine));

        // ─── 8. RepoSettlement ────────────────────────────────────
        // constructor(address _tTBILL, address _USDC, address _initialOwner)
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
        // $980.00 → 8 decimals → 98_000_000
        oracle.updatePrice(98_000_000);
        console.log("Oracle price set to $980.00");

        // ─── 11. Grant LendingPool minter role on rpUSDC ──────────
        // RepoPoolToken uses setLendingPool() not setMinter()
        rpUSDC.setLendingPool(address(lendingPool));
        console.log("rpUSDC minter set to LendingPool");

        vm.stopBroadcast();

        // ─── 12. Write addresses.json ─────────────────────────────
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
