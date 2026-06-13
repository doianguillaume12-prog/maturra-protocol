// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { MaturraOracle }    from "../src/MaturraOracle.sol";

/// @notice Deploys ONLY MaturraOracle (Pyth-wired version) on Base Sepolia.
///         All other protocol contracts are left untouched.
///
///         Wiring:
///           truflationFeed → MockTruflation already deployed at 0x31fb...
///           pythFeed       → Real Pyth contract at 0xA2aa... (Base Sepolia)
///           dao + keeper   → DEPLOYER_KEY address (same as original deploy)
contract DeployOracle is Script {

    // Real Pyth contract on Base Sepolia
    // Source: https://docs.pyth.network/price-feeds/contract-addresses/evm
    address constant PYTH_BASE_SEPOLIA = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    // Existing MockTruflation from the initial testnet deploy (tx 0xfed556...)
    // Reused to avoid unnecessary redeployment — returns 2.28% fresh.
    address constant MOCK_TRUFLATION   = 0x31fbADaDE8512bc7d0091C3aCD4F00391deC4c31;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("=== MATURRA ORACLE DEPLOYMENT (Pyth-wired) ===");
        console2.log("Deployer        :", deployer);
        console2.log("Pyth contract   :", PYTH_BASE_SEPOLIA);
        console2.log("MockTruflation  :", MOCK_TRUFLATION);
        console2.log("DAO + Keeper    :", deployer);

        vm.startBroadcast(deployerKey);

        MaturraOracle oracle = new MaturraOracle(
            MOCK_TRUFLATION,
            PYTH_BASE_SEPOLIA,
            deployer, // dao
            deployer  // keeper
        );

        vm.stopBroadcast();

        console2.log("---");
        console2.log("MaturraOracle (Pyth-wired) :", address(oracle));
        console2.log("PYTH_CPI_ID                :", vm.toString(oracle.PYTH_CPI_ID()));
        console2.log("CPI_STALENESS_LIMIT (days) :", oracle.CPI_STALENESS_LIMIT() / 1 days);
        console2.log("STALENESS_LIMIT (hours)    :", oracle.STALENESS_LIMIT() / 1 hours);
        (uint256 tw, uint256 pw) = oracle.getWeights();
        console2.log("Truflation weight          :", tw);
        console2.log("Pyth weight                :", pw);
    }
}
