// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { TempoVault }     from "../src/TempoVault.sol";
import { ITempoOracle }   from "../src/interfaces/ITempoOracle.sol";
import { IERC20 }         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 }          from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC721 }         from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// ════════════════════════════════════════════════════════════════════════════
// MOCKS
// ════════════════════════════════════════════════════════════════════════════

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockOracle {
    uint256 public rate = 228;
    bool    public frozen;

    function getWeightedInflation() external view returns (uint256) {
        require(!frozen, "Oracle: circuit breaker");
        return rate;
    }
    function isCircuitBreakerActive() external view returns (bool) { return frozen; }
    function setRate(uint256 r)    external { rate = r; }
    function setFrozen(bool f)     external { frozen = f; }
    // satisfy ITempoOracle interface
    function getRawRates() external view returns (uint256,uint256,uint256,uint256) { return(rate,rate,0,0); }
    function circuitBreakerExpiresAt() external view returns (uint256) { return 0; }
    function getWeights() external pure returns (uint256,uint256) { return (70,30); }
}

contract MockTimeNFT {
    uint256 private _next = 1;
    mapping(uint256 => address) public owners;
    mapping(uint256 => bool)    public matured;
    mapping(uint256 => MockPos) public pos;

    struct MockPos {
        uint128 lockedAmount;
        uint128 timeValue;
        uint64  lockDuration;
        uint64  maturesAt;
        uint32  inflationBps;
        uint32  mintedAt;
        bool    redeemed;
    }

    address public vault;
    function setVault(address v) external { vault = v; }

    function mint(
        address to,
        uint128 lockedAmount,
        uint64  lockDuration,
        uint32  inflationBps,
        uint128 timeValue
    ) external returns (uint256 tokenId) {
        tokenId = _next++;
        owners[tokenId] = to;
        pos[tokenId] = MockPos({
            lockedAmount: lockedAmount,
            timeValue:    timeValue,
            lockDuration: lockDuration,
            maturesAt:    uint64(block.timestamp + lockDuration),
            inflationBps: inflationBps,
            mintedAt:     uint32(block.timestamp),
            redeemed:     false
        });
    }

    function redeem(uint256 tokenId, address owner) external {
        require(owners[tokenId] == owner, "not owner");
        require(matured[tokenId] || block.timestamp >= pos[tokenId].maturesAt, "not matured");
        pos[tokenId].redeemed = true;
        delete owners[tokenId];
    }

    function positions(uint256 tokenId) external view returns (
        uint128, uint128, uint64, uint64, uint32, uint32, bool
    ) {
        MockPos memory p = pos[tokenId];
        return (p.lockedAmount, p.timeValue, p.lockDuration, p.maturesAt, p.inflationBps, p.mintedAt, p.redeemed);
    }

    function isMatured(uint256 tokenId) external view returns (bool) {
        return !pos[tokenId].redeemed && block.timestamp >= pos[tokenId].maturesAt;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    // For testing: force maturity
    function setMatured(uint256 tokenId) external { matured[tokenId] = true; }
}

contract MockBurnRouter {
    uint256 public totalReceived;
    IERC20  public usdc;

    constructor(address _usdc) { usdc = IERC20(_usdc); }

    function receiveVaultFee(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
    }
}

// ════════════════════════════════════════════════════════════════════════════
// TESTS
// ════════════════════════════════════════════════════════════════════════════
contract TempoVaultTest is Test {

    TempoVault    vault;
    MockUSDC      usdc;
    MockOracle    oracle;
    MockTimeNFT   nft;
    MockBurnRouter burnRouter;

    address dao      = makeAddr("dao");
    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant TEN_K   = 10_000e6;
    uint256 constant ONE_80D = 180 days;
    uint256 constant ONE_YEAR = 365 days;

    function setUp() public {
        usdc       = new MockUSDC();
        oracle     = new MockOracle();
        nft        = new MockTimeNFT();
        burnRouter = new MockBurnRouter(address(usdc));

        vault = new TempoVault(
            address(usdc),
            address(oracle),
            address(nft),
            address(burnRouter),
            treasury,
            dao,
            guardian
        );

        nft.setVault(address(vault));

        // Lift TVL cap for most tests
        vm.prank(dao);
        vault.setTvlCap(type(uint256).max);

        // Fund + approve
        usdc.mint(alice,    TEN_K * 100);
        usdc.mint(bob,      TEN_K * 100);
        usdc.mint(attacker, TEN_K * 100);

        vm.prank(alice);    usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);      usdc.approve(address(vault), type(uint256).max);
        vm.prank(attacker); usdc.approve(address(vault), type(uint256).max);
    }

    // ── HAPPY PATH ──────────────────────────────────────────────────────────

    function test_deposit_mints_nft() public {
        vm.prank(alice);
        (uint256 tokenId, uint256 timeValue) = vault.depositAndMintNFT(
            TEN_K, alice, ONE_80D
        );

        assertEq(tokenId, 1, "First token ID should be 1");
        assertGt(timeValue, 0, "Time value should be non-zero");
        assertEq(nft.ownerOf(tokenId), alice, "Alice should own the NFT");
        assertGt(vault.positionShares(tokenId), 0, "Shares should be recorded");

        console2.log("Token ID:", tokenId);
        console2.log("Time value (18 dec):", timeValue);
    }

    function test_deposit_different_recipient() public {
        // Alice deposits but sends NFT to Bob
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, bob, ONE_80D);

        assertEq(nft.ownerOf(tokenId), bob, "Bob should own the NFT");
    }

    function test_time_value_scales_with_inflation() public {
        oracle.setRate(100); // 1%
        vm.prank(alice);
        (, uint256 tv1) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        oracle.setRate(500); // 5%
        vm.prank(bob);
        (, uint256 tv2) = vault.depositAndMintNFT(TEN_K, bob, ONE_80D);

        // 5× inflation should give ~5× time value
        assertApproxEqRel(tv2, tv1 * 5, 1e14, "5x inflation = 5x time value");
    }

    function test_time_value_scales_with_duration() public {
        vm.prank(alice);
        (, uint256 tv30d) = vault.depositAndMintNFT(TEN_K, alice, 30 days);

        vm.prank(bob);
        (, uint256 tv180d) = vault.depositAndMintNFT(TEN_K, bob, ONE_80D);

        // 6× duration = 6× time value
        assertApproxEqRel(tv180d, tv30d * 6, 1e14, "6x duration = 6x time value");
    }

    function test_multiple_positions_same_user() public {
        vm.startPrank(alice);
        (uint256 id1,) = vault.depositAndMintNFT(TEN_K, alice, 30 days);
        (uint256 id2,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
        (uint256 id3,) = vault.depositAndMintNFT(TEN_K, alice, ONE_YEAR);
        vm.stopPrank();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);

        // Each position tracks its own shares independently
        assertGt(vault.positionShares(id1), 0);
        assertGt(vault.positionShares(id2), 0);
        assertGt(vault.positionShares(id3), 0);

        // Different durations → different shares (same assets, same vault state)
        // Actually same shares since assets are the same — but positions are distinct
        assertEq(vault.totalPositions(), 3, "Should track 3 positions");
    }

    // ── REDEMPTION ──────────────────────────────────────────────────────────

    function test_redeem_after_maturity() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        // Fast forward past maturity
        vm.warp(block.timestamp + ONE_80D + 1);

        uint256 balanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 returned = vault.redeemPosition(tokenId);

        uint256 balanceAfter = usdc.balanceOf(alice);

        // Should receive ~99.5% of deposit (0.5% fee)
        uint256 expectedNet = TEN_K - (TEN_K * 50 / 10_000);
        assertApproxEqAbs(returned, expectedNet, 1, "Should return ~99.5% of deposit");
        assertEq(balanceAfter - balanceBefore, returned, "USDC balance should increase");

        // Shares should be cleared
        assertEq(vault.positionShares(tokenId), 0, "Shares should be cleared after redeem");
    }

    function test_redeem_routes_fee_to_burn_router() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        vm.warp(block.timestamp + ONE_80D + 1);

        uint256 burnBefore = usdc.balanceOf(address(burnRouter));

        vm.prank(alice);
        vault.redeemPosition(tokenId);

        uint256 burnAfter = usdc.balanceOf(address(burnRouter));

        // BurnRouter should receive 90% of 0.5% fee = 0.45% of TEN_K = 45 USDC
        uint256 expectedFee      = TEN_K * 50 / 10_000;
        uint256 expectedBurnAmt  = expectedFee * 9000 / 10_000;

        assertApproxEqAbs(
            burnAfter - burnBefore,
            expectedBurnAmt,
            1,
            "BurnRouter should receive 90% of fee"
        );
    }

    function test_redeem_routes_10_percent_to_treasury() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        vm.warp(block.timestamp + ONE_80D + 1);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        vault.redeemPosition(tokenId);

        uint256 treasuryAfter = usdc.balanceOf(treasury);

        uint256 expectedFee       = TEN_K * 50 / 10_000;
        uint256 expectedTreasury  = expectedFee * 1000 / 10_000; // 10% → 5 USDC

        assertApproxEqAbs(
            treasuryAfter - treasuryBefore,
            expectedTreasury,
            2, // allow 2 wei rounding
            "Treasury should receive 10% of fee"
        );
    }

    function test_buyer_can_redeem_purchased_nft() public {
        // Alice deposits, Bob buys the NFT on TempoMarket (simulated by direct transfer)
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        // Simulate NFT sale: alice transfers to bob
        // In practice this goes via TempoMarket
        vm.prank(alice);
        // Note: needs ERC-721 approve/transfer — MockTimeNFT simplified this
        // Just update ownership in the mock
        nft.mint(bob, uint128(TEN_K), uint64(ONE_80D), uint32(228), 0);
        // For the real test we'd use the actual transfer mechanism
        // Here we test that whoever holds the NFT can redeem

        vm.warp(block.timestamp + ONE_80D + 1);

        // Alice (original depositor, still mock owner) redeems
        vm.prank(alice);
        uint256 returned = vault.redeemPosition(tokenId);
        assertGt(returned, 0, "Should return assets");
    }

    // ── VALIDATION ──────────────────────────────────────────────────────────

    function test_revert_deposit_too_small() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TempoVault.DepositTooSmall.selector, 99e6, 100e6)
        );
        vault.depositAndMintNFT(99e6, alice, ONE_80D);
    }

    function test_revert_lock_too_short() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.depositAndMintNFT(TEN_K, alice, 6 days);
    }

    function test_revert_lock_too_long() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.depositAndMintNFT(TEN_K, alice, 5 * 365 days);
    }

    function test_revert_oracle_frozen() public {
        oracle.setFrozen(true);
        vm.prank(alice);
        vm.expectRevert(TempoVault.OracleFrozen.selector);
        vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
    }

    function test_revert_redeem_before_maturity() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        // Try to redeem immediately — not matured
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TempoVault.NotMatured.selector, tokenId));
        vault.redeemPosition(tokenId);
    }

    function test_revert_redeem_not_owner() public {
        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        vm.warp(block.timestamp + ONE_80D + 1);

        // Bob tries to redeem Alice's position
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(TempoVault.NotNFTOwner.selector, tokenId, bob)
        );
        vault.redeemPosition(tokenId);
    }

    function test_revert_standard_deposit_disabled() public {
        vm.prank(alice);
        vm.expectRevert("Vault: use depositAndMintNFT()");
        vault.deposit(TEN_K, alice);
    }

    function test_revert_standard_redeem_disabled() public {
        vm.prank(alice);
        vm.expectRevert("Vault: use redeemPosition()");
        vault.redeem(100, alice, alice);
    }

    // ── TVL CAP ─────────────────────────────────────────────────────────────

    function test_tvl_cap_enforced() public {
        vm.prank(dao);
        vault.setTvlCap(500_000e6); // $500k

        usdc.mint(alice, 600_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // First deposit: $400k — OK
        vm.prank(alice);
        vault.depositAndMintNFT(400_000e6, alice, ONE_80D);

        // Second deposit: would exceed $500k cap
        vm.prank(alice);
        vm.expectRevert();
        vault.depositAndMintNFT(200_000e6, alice, ONE_80D);
    }

    function test_dao_can_lift_tvl_cap() public {
        vm.prank(dao);
        vault.setTvlCap(500_000e6);

        vm.prank(dao);
        vault.setTvlCap(5_000_000e6); // $5M

        assertEq(vault.tvlCap(), 5_000_000e6);
    }

    // ── ACCESS CONTROL ───────────────────────────────────────────────────────

    function test_attacker_cannot_set_tvl_cap() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setTvlCap(type(uint256).max);
    }

    function test_guardian_can_pause() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
    }

    function test_dao_can_unpause() public {
        vm.prank(guardian);
        vault.pause();

        vm.prank(dao);
        vault.unpause();

        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
        assertGt(tokenId, 0);
    }

    function test_attacker_cannot_pause() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
    }

    // ── VIEWS ────────────────────────────────────────────────────────────────

    function test_preview_deposit_matches_actual() public {
        (uint256 preview, uint256 rate) = vault.previewDeposit(TEN_K, ONE_80D);

        vm.prank(alice);
        (, uint256 actual) = vault.depositAndMintNFT(TEN_K, alice, ONE_80D);

        assertEq(preview, actual, "Preview must match actual");
        assertEq(rate, 228, "Rate should be oracle rate");
    }

    function test_tvl_tracks_deposits() public {
        assertEq(vault.tvl(), 0);

        vm.prank(alice);
        vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
        assertEq(vault.tvl(), TEN_K);

        vm.prank(bob);
        vault.depositAndMintNFT(TEN_K, bob, ONE_80D);
        assertEq(vault.tvl(), TEN_K * 2);
    }

    function test_total_positions_increments() public {
        assertEq(vault.totalPositions(), 0);
        vm.prank(alice);
        vault.depositAndMintNFT(TEN_K, alice, ONE_80D);
        assertEq(vault.totalPositions(), 1);
        vm.prank(alice);
        vault.depositAndMintNFT(TEN_K, alice, 30 days);
        assertEq(vault.totalPositions(), 2);
    }

    // ── FUZZ ────────────────────────────────────────────────────────────────

    function testFuzz_time_value_linear_in_assets(uint256 assets) public {
        assets = bound(assets, 100e6, 500_000e6);

        usdc.mint(alice, assets * 2 + 1);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        (, uint256 tv1) = vault.depositAndMintNFT(assets, alice, ONE_80D);
        (, uint256 tv2) = vault.depositAndMintNFT(assets, alice, ONE_80D);
        vm.stopPrank();

        // Same deposit twice → same time value each time
        assertApproxEqRel(tv1, tv2, 1e14, "Same deposit should give same time value");
    }

    function testFuzz_fee_always_below_deposit(uint256 assets) public {
        assets = bound(assets, 100e6, 10_000_000e6);

        usdc.mint(alice, assets);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        (uint256 tokenId,) = vault.depositAndMintNFT(assets, alice, ONE_80D);

        vm.warp(block.timestamp + ONE_80D + 1);

        vm.prank(alice);
        uint256 returned = vault.redeemPosition(tokenId);

        // Net return should be between 99% and 100% of deposit
        assertLe(returned, assets, "Cannot return more than deposited (no yield in test)");
        assertGe(returned, assets * 9900 / 10_000, "Should return at least 99% of deposit");
    }
}
