// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console } from "forge-std/Test.sol";

interface IVault {
    function redeemPosition(uint256 tokenId) external returns (uint256 assetsOut);
    function positionShares(uint256 tokenId) external view returns (uint256);
}
interface ITimeNFT {
    function ownerOf(uint256 id) external view returns (address);
    function isMatured(uint256 id) external view returns (bool);
}
interface IERC20 {
    function balanceOf(address who) external view returns (uint256);
}

contract RedeemForkTest is Test {
    address constant VAULT   = 0x484E79aF968f9cB6f338cb60435c2826f76BCCE3;
    address constant TIMENFT = 0x99f6FB3B294B96A05BCf8a20F9e7E5E2e572256B;
    address constant USDC    = 0x04339F5bB607679dF7DF08Ac076552bd7724321D;
    address constant BUYER   = 0x9Ee83814a8239280aA5422f864fcba2571A77612;
    uint256 constant TOKEN_ID = 1;

    function testRedeemAtMaturity() external {
        vm.createSelectFork("https://sepolia.base.org");

        console.log("=== BEFORE ===");
        console.log("NFT #1 owner:", ITimeNFT(TIMENFT).ownerOf(TOKEN_ID));
        console.log("isMatured:", ITimeNFT(TIMENFT).isMatured(TOKEN_ID));
        console.log("Buyer USDC before:", IERC20(USDC).balanceOf(BUYER));
        console.log("Position shares:", IVault(VAULT).positionShares(TOKEN_ID));

        vm.warp(block.timestamp + 30 days);
        console.log("");
        console.log("=== TIME WARPED +30 days ===");
        console.log("isMatured now:", ITimeNFT(TIMENFT).isMatured(TOKEN_ID));

        vm.prank(BUYER);
        uint256 out = IVault(VAULT).redeemPosition(TOKEN_ID);

        console.log("");
        console.log("=== AFTER REDEEM ===");
        console.log("Assets returned to buyer:", out);
        console.log("Buyer USDC after:", IERC20(USDC).balanceOf(BUYER));
    }
}
