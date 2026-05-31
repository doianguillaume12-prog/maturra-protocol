// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";

// Import all contracts
import { TempoOracle }  from "../src/TempoOracle.sol";
import { TimeNFT }      from "../src/TimeNFT.sol";
import { TempoToken }   from "../src/TempoToken.sol";
import { BurnRouter }   from "../src/BurnRouter.sol";
import { TempoMarket }  from "../src/TempoMarket.sol";
import { TempoVault }   from "../src/TempoVault.sol";
import { IERC20 }       from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 }        from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ========================================════════════════════════════════════
// TEST DOUBLES - Full mock implementations
// ========================================════════════════════════════════════

contract TestUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Mock oracle that returns configurable inflation rates
contract TestOracle {
    uint256 public inflationBps = 228; // 2.28%
    bool    public circuitOpen;

    function getWeightedInflation() external view returns (uint256) {
        require(!circuitOpen, "Oracle: circuit breaker");
        return inflationBps;
    }
    function isCircuitBreakerActive() external view returns (bool) { return circuitOpen; }
    function setInflation(uint256 bps) external { inflationBps = bps; }
    function openCircuit()             external { circuitOpen = true; }
    function closeCircuit()            external { circuitOpen = false; }
    // Interface stubs
    function getRawRates() external view returns (uint256,uint256,uint256,uint256) {
        return(inflationBps, inflationBps, 0, 0);
    }
    function circuitBreakerExpiresAt() external pure returns (uint256) { return 0; }
    function getWeights() external pure returns (uint256,uint256) { return (70, 30); }
}

/// @dev Mock Uniswap router - simulates USDC -> TEMPO swap at 1:1 rate for testing
contract TestSwapRouter {
    TestUSDC  public usdc;
    TempoToken public tempo;

    constructor(address _usdc, address _tempo) {
        usdc  = TestUSDC(_usdc);
        tempo = TempoToken(_tempo);
    }

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev Simulates a 1 USDC = 10 TEMPO swap (simplified for testing)
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        // Pull USDC from caller
        usdc.transferFrom(msg.sender, address(this), params.amountIn);

        // Give TEMPO to recipient (10x rate for easy math in tests)
        // In production: real Uniswap pool determines the rate
        amountOut = params.amountIn * 10 * 1e12; // USDC 6dec -> TEMPO 18dec, 10x

        // Mint test TEMPO (in production, pool has real TEMPO liquidity)
        // This requires tempo to allow minting - in real deployment, pool holds TEMPO
        // For tests: we pre-fund the router with TEMPO
        tempo.transfer(params.recipient, amountOut);
    }
}

// ========================================════════════════════════════════════
/// @title  IntegrationTest
/// @notice End-to-end tests of the complete TEMPO Protocol stack.
///         Deploys all real contracts (not mocks for the protocol contracts)
///         and exercises the full user journey.
// ========================================════════════════════════════════════
contract IntegrationTest is Test {

    // Protocol contracts
    TestOracle   oracle;
    TimeNFT      nft;
    TempoToken   tempo;
    BurnRouter   burnRouter;
    TempoMarket  market;
    TempoVault   vault;

    // Test infrastructure
    TestUSDC       usdc;
    TestSwapRouter swapRouter;

    // Actors
    address dao      = makeAddr("dao");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");   // primary depositor
    address bob      = makeAddr("bob");     // secondary buyer
    address carol    = makeAddr("carol");   // another depositor
    address keeper   = makeAddr("keeper");  // burn executor

    // Constants
    uint256 constant TEN_K    = 10_000e6;
    uint256 constant ONE_80D  = 180 days;
    uint256 constant ONE_YEAR = 365 days;

    function setUp() public {
        // ── Deploy infrastructure ──────────────────────────────────────────
        usdc   = new TestUSDC();
        oracle = new TestOracle();

        // Deploy TempoToken first (treasury gets all supply)
        tempo = new TempoToken(dao, dao, dao); // dao as placeholder burnRouter

        // Deploy swap router mock (needs tempo to give to callers)
        swapRouter = new TestSwapRouter(address(usdc), address(tempo));

        // Fund swap router with TEMPO for test swaps
        vm.prank(dao);
        tempo.transfer(address(swapRouter), 500_000_000 * 1e18);

        // Deploy BurnRouter
        burnRouter = new BurnRouter(
            address(usdc),
            address(tempo),
            address(swapRouter),
            dao
        );

        // Grant real BURN_ROUTER_ROLE
        vm.prank(dao);
        tempo.grantRole(keccak256("BURN_ROUTER_ROLE"), address(burnRouter));

        // Deploy TimeNFT (dao as vault placeholder)
        nft = new TimeNFT(dao, address(burnRouter));

        // Deploy Vault
        vault = new TempoVault(
            address(usdc),
            address(oracle),
            address(nft),
            address(burnRouter),
            treasury,
            dao,
            guardian
        );

        // Grant VAULT_ROLE
        vm.startPrank(dao);
        nft.grantRole(keccak256("VAULT_ROLE"), address(vault));
        vault.setTvlCap(type(uint256).max); // lift cap for tests
        vm.stopPrank();

        // Deploy Market
        market = new TempoMarket(
            address(nft),
            address(usdc),
            dao,
            guardian
        );

        // Fund actors
        usdc.mint(alice,   TEN_K * 100);
        usdc.mint(bob,     TEN_K * 100);
        usdc.mint(carol,   TEN_K * 100);

        vm.prank(alice); usdc.approve(address(vault),  type(uint256).max);
        vm.prank(bob);   usdc.approve(address(vault),  type(uint256).max);
        vm.prank(carol); usdc.approve(address(vault),  type(uint256).max);
        vm.prank(alice); usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);   usdc.approve(address(market), type(uint256).max);

        // BurnRouter needs approval from vault (for fee transfer)
        vm.prank(address(vault));
        usdc.approve(address(burnRouter), type(uint256).max);
    }

    // ========================================════════════════════════════════
    // JOURNEY 1: Alice deposits -> holds to maturity -> redeems
    // ========================================════════════════════════════════

    function test_journey_deposit_hold_redeem() public {
        console2.log("=== JOURNEY 1: Deposit -> Hold -> Redeem ===");

        uint256 aliceBalBefore = usdc.balanceOf(alice);

        // Alice deposits 10k USDC for 180 days
        vm.prank(alice);
        (uint256 tokenId, uint256 timeValue) = vault.depositAndMintNFT(
            TEN_K, alice, ONE_80D
        );

        console2.log("Deposited: 10,000 USDC");
        console2.log("NFT tokenId:", tokenId);
        console2.log("Time value (units):", timeValue / 1e18);

        // Verify NFT ownership
        assertEq(nft.ownerOf(tokenId), alice);
        assertEq(vault.tvl(), TEN_K);

        // Time passes
        vm.warp(block.timestamp + ONE_80D + 1 seconds);

        // NFT should be matured
        assertTrue(nft.isMatured(tokenId), "Should be matured");

        // Alice redeems
        vm.prank(alice);
        uint256 returned = vault.redeemPosition(tokenId);

        console2.log("USDC returned:", returned / 1e6);
        console2.log("Fee paid (0.5%):", (TEN_K - returned) / 1e6);

        // Should receive ~99.5% of deposit
        assertApproxEqAbs(returned, TEN_K * 9950 / 10_000, 1);
        assertLt(usdc.balanceOf(alice), aliceBalBefore, "Alice paid fees");
        assertEq(vault.tvl(), 0, "TVL should be 0 after redeem");

        console2.log(" Journey 1 complete");
    }

    // ========================================════════════════════════════════
    // JOURNEY 2: Alice deposits -> sells NFT on market -> Bob redeems
    // ========================================════════════════════════════════

    function test_journey_sell_on_market() public {
        console2.log("=== JOURNEY 2: Deposit -> Sell NFT -> Buyer Redeems ===");

        // Alice deposits
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        // Alice approves market to take the NFT
        vm.prank(alice);
        nft.approve(address(market), tokenId);

        // Alice lists at 9,500 USDC (selling at a discount for liquidity)
        uint256 askPrice = 9_500e6;
        vm.prank(alice);
        market.list(tokenId, askPrice);

        assertTrue(market.isListed(tokenId), "Should be listed");
        console2.log("Alice listed NFT at: $9,500 USDC");

        // Bob buys the position
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.buy(tokenId);

        // Bob now owns the NFT
        assertEq(nft.ownerOf(tokenId), bob, "Bob should own NFT");

        // Verify royalty went to BurnRouter
        uint256 royaltyAmt = askPrice * 100 / 10_000; // 1%
        assertApproxEqAbs(
            usdc.balanceOf(address(burnRouter)),
            royaltyAmt,
            1,
            "BurnRouter should have received royalty"
        );
        console2.log("Royalty to BurnRouter: $", royaltyAmt / 1e6);

        // Alice received: askPrice - royalty
        uint256 aliceReceived = askPrice - royaltyAmt;
        console2.log("Alice received: $", aliceReceived / 1e6);

        // Fast forward: Bob waits for maturity
        vm.warp(block.timestamp + ONE_80D + 1 seconds);

        // Bob redeems
        vm.prank(bob);
        uint256 returned = vault.redeemPosition(tokenId);
        console2.log("Bob redeemed: $", returned / 1e6);

        // Bob paid 9,500 and got back ~9,950 (if no yield) -> profit
        assertGt(returned, 0, "Bob should receive assets");
        console2.log(" Journey 2 complete");
    }

    // ========================================════════════════════════════════
    // JOURNEY 3: Burn engine - fees accumulate -> keeper executes burn
    // ========================================════════════════════════════════

    function test_journey_burn_engine() public {
        console2.log("=== JOURNEY 3: Burn Engine ===");

        // Multiple users deposit
        vm.prank(alice);
        (uint256 id1,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
        vm.prank(bob);
        (uint256 id2,) = vault.depositAndMintNFT(TEN_K, bob, ONE_80D);
        vm.prank(carol);
        (uint256 id3,) = vault.depositAndMintNFT(TEN_K, carol, ONE_80D);

        console2.log("3 deposits of $10k each. TVL:", vault.tvl() / 1e6);

        // All mature
        vm.warp(block.timestamp + ONE_80D + 1 seconds);

        uint256 tempoBefore = tempo.totalSupply();

        // All redeem
        vm.prank(alice); vault.redeemPosition(id1);
        vm.prank(bob);   vault.redeemPosition(id2);
        vm.prank(carol); vault.redeemPosition(id3);

        uint256 burnRouterBal = usdc.balanceOf(address(burnRouter));
        console2.log("BurnRouter USDC accumulated: $", burnRouterBal / 1e6);

        // Verify enough for burn
        assertTrue(burnRouter.canExecuteBurn(), "Should be able to execute burn");

        // Give BurnRouter approval to spend USDC from itself (already approved via constructor)
        // Keeper executes the burn
        vm.prank(keeper);
        uint256 tempoBurned = burnRouter.executeBurn();

        uint256 tempoAfter = tempo.totalSupply();

        console2.log("TEMPO burned:", tempoBurned / 1e18);
        assertGt(tempoBurned, 0, "Should have burned TEMPO");
        assertLt(tempoAfter, tempoBefore, "TEMPO supply should decrease");
        assertEq(tempo.totalBurned(), tempoBurned, "totalBurned should track correctly");

        console2.log(" Journey 3 complete - Supply went from",
            tempoBefore / 1e18, "to", tempoAfter / 1e18);
    }

    // ========================================════════════════════════════════
    // JOURNEY 4: Multi-position same user
    // ========================================════════════════════════════════

    function test_journey_multi_position() public {
        console2.log("=== JOURNEY 4: Multi-position same user ===");

        // Alice creates 3 positions with different durations
        vm.startPrank(alice);
        (uint256 id1, uint256 tv1) = vault.depositAndMintNFT(TEN_K, alice, 30  days);
        (uint256 id2, uint256 tv2) = vault.depositAndMintNFT(TEN_K, alice, 90  days);
        (uint256 id3, uint256 tv3) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(vault.totalPositions(), 3);
        assertEq(vault.tvl(), TEN_K * 3);

        // Time values should scale with duration
        assertGt(tv2, tv1, "90d should have more time value than 30d");
        assertGt(tv3, tv2, "180d should have more time value than 90d");

        console2.log("Position 1 (30d) time value:", tv1 / 1e18);
        console2.log("Position 2 (90d) time value:", tv2 / 1e18);
        console2.log("Position 3 (180d) time value:", tv3 / 1e18);

        // Redeem as they mature
        vm.warp(block.timestamp + 30 days + 1 seconds);
        assertTrue(nft.isMatured(id1), "id1 should be matured");
        assertFalse(nft.isMatured(id2), "id2 should not be matured yet");

        vm.prank(alice);
        vault.redeemPosition(id1);

        // id1 gone, id2 and id3 still active
        assertEq(vault.positionShares(id1), 0, "id1 shares cleared");
        assertGt(vault.positionShares(id2), 0, "id2 shares still active");
        assertGt(vault.positionShares(id3), 0, "id3 shares still active");

        console2.log(" Journey 4 complete");
    }

    // ========================================════════════════════════════════
    // SECURITY: Replay attack - can't redeem same NFT twice
    // ========================================════════════════════════════════

    function test_security_no_double_redeem() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        vm.warp(block.timestamp + ONE_80D + 1 seconds);

        // First redeem: succeeds
        vm.prank(alice);
        vault.redeemPosition(tokenId);

        // Second redeem: should fail - NFT burned, alice no longer owner
        vm.prank(alice);
        vm.expectRevert(); // NotNFTOwner or ownerOf reverts on burned token
        vault.redeemPosition(tokenId);

        console2.log(" Double redeem correctly prevented");
    }

    // ========================================════════════════════════════════
    // SECURITY: Non-owner cannot redeem
    // ========================================════════════════════════════════

    function test_security_only_owner_redeems() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        vm.warp(block.timestamp + ONE_80D + 1 seconds);

        // Bob (not owner) tries to redeem Alice's position
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(TempoVault.NotNFTOwner.selector, tokenId, bob)
        );
        vault.redeemPosition(tokenId);

        console2.log(" Non-owner redeem correctly prevented");
    }

    // ========================================════════════════════════════════
    // ECONOMIC: Deflationary pressure increases with volume
    // ========================================════════════════════════════════

    function test_economic_deflationary_pressure() public {
        uint256 initialSupply = tempo.totalSupply();
        console2.log("Initial TEMPO supply:", initialSupply / 1e18);

        // 10 deposits and redeems
        for (uint256 i = 0; i < 10; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));
            usdc.mint(user, TEN_K);
            vm.prank(user); usdc.approve(address(vault), type(uint256).max);
            vm.prank(user); (uint256 id,) = vault.depositAndMintNFT(TEN_K, user, ONE_80D);
            vm.warp(block.timestamp + ONE_80D + 1);
            vm.prank(user); vault.redeemPosition(id);
            vm.warp(block.timestamp + 1);
        }

        // Execute burns
        if (burnRouter.canExecuteBurn()) {
            burnRouter.executeBurn();
        }

        uint256 finalSupply = tempo.totalSupply();
        console2.log("Final TEMPO supply:", finalSupply / 1e18);
        console2.log("TEMPO burned:", (initialSupply - finalSupply) / 1e18);

        assertLt(finalSupply, initialSupply, "Supply must decrease after burns");
        console2.log(" Deflationary pressure confirmed");
    }

    // ========================================════════════════════════════════
    // MARKET: List, cancel, relist
    // ========================================════════════════════════════════

    function test_market_list_cancel_relist() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        vm.prank(alice);
        nft.approve(address(market), tokenId);

        // List at 9k
        vm.prank(alice);
        market.list(tokenId, 9_000e6);
        assertTrue(market.isListed(tokenId));

        // Cancel
        vm.prank(alice);
        market.cancel(tokenId);
        assertFalse(market.isListed(tokenId));
        assertEq(nft.ownerOf(tokenId), alice, "NFT returned to Alice");

        // Relist at higher price
        vm.prank(alice);
        nft.approve(address(market), tokenId);
        vm.prank(alice);
        market.list(tokenId, 9_800e6);
        assertTrue(market.isListed(tokenId));

        // Update price
        vm.prank(alice);
        market.updatePrice(tokenId, 9_500e6);
        (,uint256 price,) = market.listings(tokenId);
        assertEq(price, 9_500e6, "Price should be updated");

        console2.log(" Market list/cancel/relist complete");
    }
}
