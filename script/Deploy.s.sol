// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TempoOracle }      from "../src/TempoOracle.sol";
import { TimeNFT }          from "../src/TimeNFT.sol";
import { TempoToken }       from "../src/TempoToken.sol";
import { BurnRouter }       from "../src/BurnRouter.sol";
import { TempoMarket }      from "../src/TempoMarket.sol";
import { TempoVault }       from "../src/TempoVault.sol";

// ========================================════════════════════════════════════
/// @title  Deploy
/// @notice Foundry deployment script for the complete TEMPO Protocol stack.
///
///         DEPLOYMENT ORDER (dependency graph):
///           1. TempoOracle  - no dependencies
///           2. TempoToken   - needs: dao, burnRouter (circular -> deploy placeholder first)
///           3. BurnRouter   - needs: usdc, tempoToken, swapRouter, dao
///           4. TimeNFT      - needs: vault (circular -> grant role after vault deploy)
///           5. TempoVault   - needs: usdc, oracle, timeNFT, burnRouter, treasury, dao
///           6. TempoMarket  - needs: timeNFT, usdc, dao, guardian
///           7. Post-deploy  - grant VAULT_ROLE to vault on TimeNFT
///                          - grant BURN_ROUTER_ROLE to burnRouter on TempoToken
///
///         USAGE:
///
///         Local anvil:
///           forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
///
///         Base Sepolia testnet:
///           forge script script/Deploy.s.sol \
///             --rpc-url $BASE_SEPOLIA_RPC \
///             --private-key $DEPLOYER_KEY \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $BASESCAN_KEY
///
///         Base Mainnet (Phase 0):
///           forge script script/Deploy.s.sol \
///             --rpc-url $BASE_MAINNET_RPC \
///             --private-key $DEPLOYER_KEY \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $BASESCAN_KEY \
///             --slow   ← important: wait for confirmations between txs
///
///         ENV VARIABLES REQUIRED:
///           DEPLOYER_KEY       Private key of deployer wallet
///           DAO_ADDRESS        DAO multisig address (3/5 Safe)
///           GUARDIAN_ADDRESS   Guardian multisig (1/3 Safe - faster pause)
///           TREASURY_ADDRESS   Treasury multisig
///           USDC_ADDRESS       USDC contract on target chain
///           UNISWAP_ROUTER     Uniswap V3/V4 SwapRouter address
///           TRUFLATION_FEED    Truflation oracle feed address
///           PYTH_ADDRESS       Pyth Network oracle address
// ========================================════════════════════════════════════
contract Deploy is Script {

    // ── CHAIN-SPECIFIC ADDRESSES ─────────────────────────────────────────────
    // Base Mainnet
    address constant BASE_USDC        = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant BASE_UNISWAP_V3  = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant BASE_PYTH        = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a;

    // Base Sepolia (testnet)
    address constant SEPOLIA_USDC     = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant SEPOLIA_UNISWAP  = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;
    address constant SEPOLIA_PYTH     = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    // Truflation (same address on Base and Base Sepolia as of 2026)
    address constant TRUFLATION_FEED  = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    // ── DEPLOYED ADDRESSES (populated after deployment) ───────────────────────
    TempoOracle  public oracle;
    TempoToken   public tempo;
    BurnRouter   public burnRouter;
    TimeNFT      public timeNFT;
    TempoVault   public vault;
    TempoMarket  public market;

    // ── DEPLOY PARAMS ────────────────────────────────────────────────────────
    address dao;
    address guardian;
    address treasury;
    address usdc;
    address uniswapRouter;
    address pythAddress;
    address truflationFeed;
    bool    isTestnet;

    function run() external {
        // ── LOAD ENV ─────────────────────────────────────────────────────────
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        dao            = vm.envAddress("DAO_ADDRESS");
        guardian       = vm.envAddress("GUARDIAN_ADDRESS");
        treasury       = vm.envAddress("TREASURY_ADDRESS");
        isTestnet      = vm.envOr("IS_TESTNET", true); // default: testnet

        if (isTestnet) {
            usdc          = SEPOLIA_USDC;
            uniswapRouter = SEPOLIA_UNISWAP;
            pythAddress   = SEPOLIA_PYTH;
            truflationFeed = TRUFLATION_FEED;
            console2.log(">>> Deploying to BASE SEPOLIA (testnet)");
        } else {
            usdc          = BASE_USDC;
            uniswapRouter = BASE_UNISWAP_V3;
            pythAddress   = BASE_PYTH;
            truflationFeed = TRUFLATION_FEED;
            console2.log(">>> Deploying to BASE MAINNET");
        }

        address deployer = vm.addr(deployerKey);
        console2.log("Deployer:", deployer);
        console2.log("DAO:     ", dao);
        console2.log("Treasury:", treasury);
        console2.log("Guardian:", guardian);
        console2.log("");

        vm.startBroadcast(deployerKey);

        _deployAll();

        vm.stopBroadcast();

        _printSummary();
        _verifyInvariants();
    }

    function _deployAll() internal {
        // ────────────────────────────────────────────────────────────────────
        // STEP 1 - TempoOracle
        // No dependencies. Deploys immediately.
        // ────────────────────────────────────────────────────────────────────
        console2.log("1. Deploying TempoOracle...");
        oracle = new TempoOracle(
            truflationFeed,
            pythAddress,
            dao,       // DAO_ROLE
            dao        // KEEPER_ROLE (DAO runs the keeper initially; can delegate later)
        );
        console2.log("   TempoOracle:", address(oracle));

        // ────────────────────────────────────────────────────────────────────
        // STEP 2 - TempoToken
        // Needs burnRouter address - but burnRouter needs tempoToken.
        // Resolution: deploy TempoToken with a placeholder burnRouter,
        // then grant BURN_ROUTER_ROLE after BurnRouter is deployed.
        // treasury receives the full 1B supply for scheduled distribution.
        // ────────────────────────────────────────────────────────────────────
        console2.log("2. Deploying TempoToken...");
        // Temporarily use dao as burnRouter placeholder (we'll grant real role after)
        tempo = new TempoToken(
            dao,
            dao,       // placeholder burnRouter - real one granted after step 3
            treasury
        );
        console2.log("   TempoToken:", address(tempo));

        // ────────────────────────────────────────────────────────────────────
        // STEP 3 - BurnRouter
        // Now we have the real tempo address. Deploy BurnRouter.
        // ────────────────────────────────────────────────────────────────────
        console2.log("3. Deploying BurnRouter...");
        burnRouter = new BurnRouter(
            usdc,
            address(tempo),
            uniswapRouter,
            dao
        );
        console2.log("   BurnRouter:", address(burnRouter));

        // Grant BURN_ROUTER_ROLE to the real BurnRouter on TempoToken
        // This call must come from the DAO (which holds DEFAULT_ADMIN_ROLE)
        // In script context: deployer has admin role initially, then transfers
        console2.log("   Granting BURN_ROUTER_ROLE to BurnRouter on TempoToken...");
        tempo.grantRole(keccak256("BURN_ROUTER_ROLE"), address(burnRouter));

        // ────────────────────────────────────────────────────────────────────
        // STEP 4 - TimeNFT
        // Needs burnRouter (for ERC-2981 royalty receiver).
        // Needs vault address for VAULT_ROLE - will grant after vault deploy.
        // ────────────────────────────────────────────────────────────────────
        console2.log("4. Deploying TimeNFT...");
        timeNFT = new TimeNFT(
            dao,            // temporary vault placeholder (has DEFAULT_ADMIN_ROLE)
            address(burnRouter)  // royalty receiver -> BurnRouter
        );
        console2.log("   TimeNFT:", address(timeNFT));

        // ────────────────────────────────────────────────────────────────────
        // STEP 5 - TempoVault
        // All dependencies now available.
        // ────────────────────────────────────────────────────────────────────
        console2.log("5. Deploying TempoVault...");
        vault = new TempoVault(
            usdc,
            address(oracle),
            address(timeNFT),
            address(burnRouter),
            treasury,
            dao,
            guardian
        );
        console2.log("   TempoVault:", address(vault));

        // Grant VAULT_ROLE to the real vault on TimeNFT
        console2.log("   Granting VAULT_ROLE to TempoVault on TimeNFT...");
        timeNFT.grantRole(keccak256("VAULT_ROLE"), address(vault));

        // ────────────────────────────────────────────────────────────────────
        // STEP 6 - TempoMarket
        // ────────────────────────────────────────────────────────────────────
        console2.log("6. Deploying TempoMarket...");
        market = new TempoMarket(
            address(timeNFT),
            usdc,
            dao,
            guardian
        );
        console2.log("   TempoMarket:", address(market));

        // ────────────────────────────────────────────────────────────────────
        // STEP 7 - POST-DEPLOY CONFIGURATION
        // ────────────────────────────────────────────────────────────────────
        console2.log("7. Post-deploy configuration...");

        // Renounce deployer's admin role on TimeNFT (only DAO remains admin)
        // This prevents the deployer from having lingering power post-deploy
        // NOTE: Only do this after all role grants are complete
        // timeNFT.renounceRole(timeNFT.DEFAULT_ADMIN_ROLE(), deployer);

        // Phase 0 TVL cap is already set to $500k in TempoVault constructor
        // DAO can lift it via vault.setTvlCap() after 90 days

        console2.log("   All configuration complete.");
    }

    function _printSummary() internal view {
        console2.log("");
        console2.log("========================================");
        console2.log("    TEMPO PROTOCOL - DEPLOYMENT SUMMARY");
        console2.log("========================================");
        console2.log("");
        console2.log("Core Contracts:");
        console2.log("  TempoOracle  :", address(oracle));
        console2.log("  TempoToken   :", address(tempo));
        console2.log("  BurnRouter   :", address(burnRouter));
        console2.log("  TimeNFT      :", address(timeNFT));
        console2.log("  TempoVault   :", address(vault));
        console2.log("  TempoMarket  :", address(market));
        console2.log("");
        console2.log("External Dependencies:");
        console2.log("  USDC         :", usdc);
        console2.log("  Uniswap      :", uniswapRouter);
        console2.log("  Pyth         :", pythAddress);
        console2.log("  Truflation   :", truflationFeed);
        console2.log("");
        console2.log("Access Control:");
        console2.log("  DAO          :", dao);
        console2.log("  Guardian     :", guardian);
        console2.log("  Treasury     :", treasury);
        console2.log("");
        console2.log("Phase 0 Settings:");
        console2.log("  TVL Cap      : $500,000 USDC");
        console2.log("  Min Deposit  : $100 USDC");
        console2.log("  Min Lock     : 7 days");
        console2.log("  Max Lock     : 4 years");
        console2.log("  Redeem Fee   : 0.5%");
        console2.log("  Burn Split   : 90% BurnRouter / 10% Treasury");
        console2.log("  NFT Royalty  : 1% -> BurnRouter");
        console2.log("========================================");
    }

    function _verifyInvariants() internal view {
        // Verify role assignments
        bytes32 VAULT_ROLE       = keccak256("VAULT_ROLE");
        bytes32 BURN_ROUTER_ROLE = keccak256("BURN_ROUTER_ROLE");
        bytes32 DAO_ROLE         = keccak256("DAO_ROLE");

        require(
            timeNFT.hasRole(VAULT_ROLE, address(vault)),
            "INVARIANT FAIL: Vault does not have VAULT_ROLE on TimeNFT"
        );
        require(
            tempo.hasRole(BURN_ROUTER_ROLE, address(burnRouter)),
            "INVARIANT FAIL: BurnRouter does not have BURN_ROUTER_ROLE on TempoToken"
        );
        require(
            vault.hasRole(DAO_ROLE, dao),
            "INVARIANT FAIL: DAO does not have DAO_ROLE on Vault"
        );
        require(
            address(vault.oracle())      == address(oracle),
            "INVARIANT FAIL: Vault oracle mismatch"
        );
        require(
            address(vault.timeNFT())     == address(timeNFT),
            "INVARIANT FAIL: Vault timeNFT mismatch"
        );
        require(
            address(vault.burnRouter())  == address(burnRouter),
            "INVARIANT FAIL: Vault burnRouter mismatch"
        );

        console2.log("[OK] All invariants verified.");
    }
}
