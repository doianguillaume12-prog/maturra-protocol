// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";

interface IERC20 {
    function transfer(address to, uint256 amt) external returns (bool);
    function approve(address spender, uint256 amt) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}
interface IERC721 {
    function approve(address to, uint256 id) external;
    function ownerOf(uint256 id) external view returns (address);
}
interface IMarket {
    function list(uint256 id, uint256 price) external;
    function buy(uint256 id) external;
    function isListed(uint256 id) external view returns (bool);
}

contract MarketCycle is Script {
    address constant MARKET   = 0x99B4DE13A50BcF93DA414708647722F9c4F1155a;
    address constant TIMENFT  = 0x99f6FB3B294B96A05BCf8a20F9e7E5E2e572256B;
    address constant USDC     = 0x04339F5bB607679dF7DF08Ac076552bd7724321D;
    uint256 constant TOKEN_ID = 1;
    uint256 constant PRICE    = 8_000_000_000;

    function run() external {
        uint256 sellerPk = vm.envUint("DEPLOYER_KEY");
        uint256 buyerPk  = vm.envUint("BUYER_KEY");
        address seller   = vm.addr(sellerPk);
        address buyer    = vm.addr(buyerPk);

        console.log("Seller (deployer):", seller);
        console.log("Buyer  (throwaway):", buyer);
        console.log("NFT #1 owner BEFORE:", IERC721(TIMENFT).ownerOf(TOKEN_ID));
        console.log("Seller USDC BEFORE:", IERC20(USDC).balanceOf(seller));

        vm.startBroadcast(sellerPk);
        IERC721(TIMENFT).approve(MARKET, TOKEN_ID);
        IMarket(MARKET).list(TOKEN_ID, PRICE);
        IERC20(USDC).transfer(buyer, PRICE);
        vm.stopBroadcast();

        console.log("Listed:", IMarket(MARKET).isListed(TOKEN_ID));
        console.log("Buyer USDC funded:", IERC20(USDC).balanceOf(buyer));

        vm.startBroadcast(buyerPk);
        IERC20(USDC).approve(MARKET, PRICE);
        IMarket(MARKET).buy(TOKEN_ID);
        vm.stopBroadcast();

        console.log("=== RESULT ===");
        console.log("NFT #1 owner AFTER:", IERC721(TIMENFT).ownerOf(TOKEN_ID));
        console.log("Seller USDC AFTER:", IERC20(USDC).balanceOf(seller));
        console.log("Buyer  USDC AFTER:", IERC20(USDC).balanceOf(buyer));
    }
}
