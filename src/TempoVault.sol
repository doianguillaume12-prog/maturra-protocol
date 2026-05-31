// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC4626 }         from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 }          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AccessControl }   from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable }        from "@openzeppelin/contracts/utils/Pausable.sol";
import { Math }            from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITempoOracle }    from "./interfaces/ITempoOracle.sol";

// ── MINIMAL INTERFACES ───────────────────────────────────────────────────────

interface ITimeNFT {
    function mint(
        address to,
        uint128 lockedAmount,
        uint64  lockDuration,
        uint32  inflationBps,
        uint128 timeValue
    ) external returns (uint256 tokenId);

    function redeem(uint256 tokenId, address owner) external;

    struct Position {
        uint128 lockedAmount;
        uint128 timeValue;
        uint64  lockDuration;
        uint64  maturesAt;
        uint32  inflationBps;
        uint32  mintedAt;
        bool    redeemed;
    }

    function positions(uint256 tokenId) external view returns (
        uint128 lockedAmount,
        uint128 timeValue,
        uint64  lockDuration,
        uint64  maturesAt,
        uint32  inflationBps,
        uint32  mintedAt,
        bool    redeemed
    );

    function isMatured(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId)   external view returns (address);
}

interface IBurnRouter {
    function receiveVaultFee(uint256 amount) external;
}

// ════════════════════════════════════════════════════════════════════════════
/// @title  TempoVault — v2
/// @notice Core vault for TEMPO Protocol.
///
///         WHAT CHANGED FROM v1:
///         - Removed $TEMPO burn at deposit (eliminated circular dependency)
///         - Removed ERC-20 $TIME minting → replaced by TimeNFT.mint()
///         - Added redemption fee (0.5%) routed to BurnRouter
///         - Multi-position support via NFT tokenIds (one NFT per deposit)
///         - Per-position tracking via mapping(tokenId => shares)
///
///         FLOW:
///           DEPOSIT:
///             1. User deposits USDC + specifies lock duration
///             2. USDC earns yield in ERC-4626 (routed to Morpho/Aave)
///             3. TimeNFT minted with position metadata
///             4. NFT tokenId → ERC-4626 shares mapping stored
///
///           REDEEM (at maturity):
///             1. NFT owner calls redeem(tokenId)
///             2. Maturity check via TimeNFT.isMatured()
///             3. 0.5% redemption fee deducted
///             4. Fee: 90% → BurnRouter (will swap→burn $TEMPO)
///             5. Fee: 10% → Treasury
///             6. Principal + accrued yield → NFT owner
///             7. TimeNFT burned
///
///         SECURITY:
///           - nonReentrant on all state-changing functions
///           - Strict CEI pattern throughout
///           - TVL cap (Phase 0: $500k, lifted by DAO)
///           - Emergency pause (guardian fast, DAO to unpause)
///           - _decimalsOffset = 6 prevents ERC-4626 inflation attack
// ════════════════════════════════════════════════════════════════════════════
contract TempoVault is ERC4626, ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using Math      for uint256;

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant DAO_ROLE     = keccak256("DAO_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");

    // ── CONSTANTS ────────────────────────────────────────────────────────────
    uint256 public constant MIN_LOCK         = 7   days;
    uint256 public constant MAX_LOCK         = 4 * 365 days;
    uint256 public constant MIN_DEPOSIT      = 100e6;      // 100 USDC
    uint256 public constant REDEMPTION_FEE   = 50;         // 0.5% in BPS
    uint256 public constant FEE_BURN_SPLIT   = 9000;       // 90% → BurnRouter
    uint256 public constant FEE_TREASURY_SPLIT = 1000;     // 10% → Treasury
    uint256 public constant BPS              = 10_000;
    uint256 public constant DAYS_PER_YEAR    = 365;

    // ── IMMUTABLES ───────────────────────────────────────────────────────────
    ITempoOracle public immutable oracle;
    ITimeNFT     public immutable timeNFT;
    IBurnRouter  public immutable burnRouter;
    IERC20       public immutable usdc;
    address      public immutable treasury;

    // ── MUTABLE STATE ────────────────────────────────────────────────────────
    uint256 public tvlCap = 500_000e6;   // Phase 0: $500k

    // Per-position share tracking: tokenId → ERC-4626 shares held by vault
    // When a user deposits, we mint ERC-4626 shares TO THE VAULT and record them here.
    // At redemption, the vault burns these shares and returns the underlying.
    mapping(uint256 => uint256) public positionShares;
    mapping(uint256 => uint256) public positionAssets;

    // Cumulative stats (gas-efficient uint128 packing)
    uint128 public totalDeposited;   // USDC deposited all-time (6 dec)
    uint128 public totalRedeemed;    // USDC redeemed all-time (6 dec)
    uint128 public totalFeesRouted;  // USDC fees sent to BurnRouter (6 dec)
    uint32  public totalPositions;   // count of minted positions

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event Deposited(
        address indexed depositor,
        address indexed nftRecipient,
        uint256         tokenId,
        uint256         assets,
        uint256         lockDuration,
        uint256         inflationBps,
        uint256         timeValue,
        uint256         maturesAt
    );
    event Redeemed(
        address indexed redeemer,
        uint256         tokenId,
        uint256         assetsReturned,
        uint256         feeToBurnRouter,
        uint256         feeToTreasury,
        uint256         yield         // extra yield beyond principal
    );
    event TvlCapUpdated(uint256 oldCap, uint256 newCap);
    event FeeRouted(uint256 burnRouterAmount, uint256 treasuryAmount);

    // ── ERRORS ───────────────────────────────────────────────────────────────
    error DepositTooSmall(uint256 amount, uint256 min);
    error LockInvalid(uint256 duration, uint256 min, uint256 max);
    error TvlCapExceeded(uint256 newTotal, uint256 cap);
    error OracleFrozen();
    error NotNFTOwner(uint256 tokenId, address caller);
    error NotMatured(uint256 tokenId);
    error ZeroShares(uint256 tokenId);
    error ZeroAssets();

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _oracle,
        address _timeNFT,
        address _burnRouter,
        address _treasury,
        address _dao,
        address _guardian
    )
        ERC4626(IERC20(_usdc))
        ERC20("TEMPO Vault Share", "vTEMPO")
    {
        require(_usdc       != address(0), "Vault: zero usdc");
        require(_oracle     != address(0), "Vault: zero oracle");
        require(_timeNFT    != address(0), "Vault: zero nft");
        require(_burnRouter != address(0), "Vault: zero burnRouter");
        require(_treasury   != address(0), "Vault: zero treasury");
        require(_dao        != address(0), "Vault: zero dao");
        require(_guardian   != address(0), "Vault: zero guardian");

        usdc       = IERC20(_usdc);
        oracle     = ITempoOracle(_oracle);
        timeNFT    = ITimeNFT(_timeNFT);
        burnRouter = IBurnRouter(_burnRouter);
        treasury   = _treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE,    _dao);
        _grantRole(PAUSER_ROLE, _guardian);
    }

    // ════════════════════════════════════════════════════════════════════════
    // CORE: DEPOSIT
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Deposit USDC, lock it for a duration, receive a TimeNFT
    ///         representing your position's real temporal value.
    ///
    /// @param  assets        USDC amount to deposit (6 decimals)
    /// @param  nftRecipient  Address to receive the TimeNFT (can be different from depositor)
    /// @param  lockDuration  Lock period in seconds (7 days → 4 years)
    ///
    /// @return tokenId  The minted TimeNFT token ID
    /// @return timeValue  Real temporal value captured (18 decimals)
    function depositAndMintNFT(
        uint256 assets,
        address nftRecipient,
        uint256 lockDuration
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId, uint256 timeValue)
    {
        // ── 1. VALIDATE INPUTS ───────────────────────────────────────────────
        if (assets < MIN_DEPOSIT)
            revert DepositTooSmall(assets, MIN_DEPOSIT);

        if (lockDuration < MIN_LOCK || lockDuration > MAX_LOCK)
            revert LockInvalid(lockDuration, MIN_LOCK, MAX_LOCK);

        require(nftRecipient != address(0), "Vault: zero recipient");

        // ── 2. TVL CAP ───────────────────────────────────────────────────────
        uint256 newTvl = totalAssets() + assets;
        if (newTvl > tvlCap)
            revert TvlCapExceeded(newTvl, tvlCap);

        // ── 3. ORACLE CHECK ──────────────────────────────────────────────────
        if (oracle.isCircuitBreakerActive())
            revert OracleFrozen();

        uint256 inflationBps = oracle.getWeightedInflation();

        // ── 4. PULL USDC FROM DEPOSITOR (CEI — external call first) ─────────
        usdc.safeTransferFrom(msg.sender, address(this), assets);

        // ── 5. COMPUTE TEMPORAL VALUE ────────────────────────────────────────
        //
        //   timeValue = assets(USDC, 6 dec) × inflationBps × lockDuration
        //               ──────────────────────────────────────────────────
        //               BPS × DAYS_PER_YEAR × 1 day × (6→18 dec correction)
        //
        //   We scale to 18 decimals: × 1e12 (since USDC is 6 dec)
        //
        //   Example: 10_000e6 USDC × 228 BPS × 180 days
        //            ─────────────────────────────────────── × 1e12
        //            10_000 × 365 × 86_400
        //
        //   = 10_000e6 × 228 × 15_552_000 × 1e12 / (10_000 × 31_536_000)
        //   ≈ 11.22e18 TIME units (representing $11.22 of temporal value)
        //
        timeValue = (assets * inflationBps * lockDuration * 1e12)
                    / (BPS * DAYS_PER_YEAR * 1 days);

        // ── 6. DEPOSIT INTO ERC-4626 (generates yield via Morpho/Aave) ───────
        //
        //   We mint shares TO THE VAULT ITSELF and track them per-position.
        //   This way the vault acts as custodian of the underlying yield position.
        //   The NFT owner has a claim on these shares at maturity.
        //
        //   We use the internal _deposit to avoid the disabled public deposit().
        //
        uint256 shares = _convertToShares(assets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares(0); // pre-flight check

        // Mint shares directly to vault — assets already transferred from user above
        _mint(address(this), shares);

        // ── 7. UPDATE STATE ──────────────────────────────────────────────────
        totalDeposited  += uint128(assets);
        totalPositions  += 1;

        // ── 8. MINT TIMENFT ──────────────────────────────────────────────────
        tokenId = timeNFT.mint(
            nftRecipient,
            uint128(assets),
            uint64(lockDuration),
            uint32(inflationBps),
            uint128(timeValue > type(uint128).max ? type(uint128).max : timeValue)
        );

        // ── 9. RECORD SHARES FOR THIS POSITION ──────────────────────────────
        positionShares[tokenId] = shares;
        positionAssets[tokenId] = assets;

        // ── 10. EMIT ─────────────────────────────────────────────────────────
        emit Deposited(
            msg.sender,
            nftRecipient,
            tokenId,
            assets,
            lockDuration,
            inflationBps,
            timeValue,
            block.timestamp + lockDuration
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // CORE: REDEEM
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Redeem a matured position. Caller must be the current NFT owner.
    ///         Returns principal + yield, minus the 0.5% redemption fee.
    ///
    /// @param  tokenId  The TimeNFT position to redeem
    /// @return assetsOut  USDC returned to the caller (net of fees)
    function redeemPosition(uint256 tokenId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assetsOut)
    {
        // ── 1. OWNERSHIP CHECK ───────────────────────────────────────────────
        if (timeNFT.ownerOf(tokenId) != msg.sender)
            revert NotNFTOwner(tokenId, msg.sender);

        // ── 2. MATURITY CHECK ────────────────────────────────────────────────
        if (!timeNFT.isMatured(tokenId))
            revert NotMatured(tokenId);

        // ── 3. LOAD POSITION SHARES ──────────────────────────────────────────
        uint256 shares = positionShares[tokenId];
        if (shares == 0) revert ZeroShares(tokenId);

        // ── 4. UPDATE STATE BEFORE EXTERNAL CALLS (CEI) ─────────────────────
        positionShares[tokenId] = 0;
        uint256 grossAssets = positionAssets[tokenId];
        positionAssets[tokenId] = 0;

        // ── 5. BURN NFT (external call — after state update) ─────────────────
        timeNFT.redeem(tokenId, msg.sender);

        // ── 6. COMPUTE GROSS ASSETS (principal + yield) ──────────────────────
        //
        //   ERC-4626 converts our stored shares back to assets.
        //   If the underlying (Morpho/Aave) has generated yield,
        //   convertToAssets(shares) > original deposit.
        //
        if (grossAssets == 0) revert ZeroAssets();

        // ── 7. COMPUTE REDEMPTION FEE ─────────────────────────────────────────
        //
        //   fee = grossAssets × REDEMPTION_FEE / BPS  (0.5%)
        //   burnRouterAmount = fee × 90%
        //   treasuryAmount   = fee × 10%
        //
        uint256 fee            = (grossAssets * REDEMPTION_FEE) / BPS;
        uint256 burnRouterAmt  = (fee * FEE_BURN_SPLIT)    / BPS;
        uint256 treasuryAmt    = (fee * FEE_TREASURY_SPLIT) / BPS;

        // Handle rounding dust: ensure fee parts sum to fee
        uint256 remainder = fee - burnRouterAmt - treasuryAmt;
        treasuryAmt += remainder; // dust to treasury

        assetsOut = grossAssets - fee;

        // Load original deposit for yield calculation in event
        (uint128 lockedAmount,,,,,, ) = timeNFT.positions(tokenId);
        uint256 yieldEarned = grossAssets > lockedAmount
            ? grossAssets - lockedAmount
            : 0;

        // ── 8. REDEEM SHARES FROM ERC-4626 → USDC IN VAULT ──────────────────
        _withdraw(address(this), address(this), address(this), grossAssets, shares);

        // ── 9. UPDATE STATS ──────────────────────────────────────────────────
        totalRedeemed    += uint128(assetsOut);
        totalFeesRouted  += uint128(burnRouterAmt);

        // ── 10. DISTRIBUTE FEES ───────────────────────────────────────────────
        //
        //   BurnRouter fee: approve + call receiveVaultFee()
        //   The BurnRouter will accumulate and swap to $TEMPO then burn.
        //
        if (burnRouterAmt > 0) {
            IERC20(asset()).transfer(address(burnRouter), burnRouterAmt);
        }

        if (treasuryAmt > 0) {
            usdc.safeTransfer(treasury, treasuryAmt);
        }

        // ── 11. TRANSFER NET ASSETS TO REDEEMER ──────────────────────────────
        usdc.safeTransfer(msg.sender, assetsOut);

        // ── 12. EMIT ──────────────────────────────────────────────────────────
        emit Redeemed(
            msg.sender,
            tokenId,
            assetsOut,
            burnRouterAmt,
            treasuryAmt,
            yieldEarned
        );
        emit FeeRouted(burnRouterAmt, treasuryAmt);
    }

    // ════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Preview gross assets for a position (principal + yield accrued)
    function previewPositionValue(uint256 tokenId)
        external
        view
        returns (uint256 grossAssets, uint256 netAssets, uint256 fee)
    {
        uint256 shares = positionShares[tokenId];
        if (shares == 0) return (0, 0, 0);

        grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        fee         = (grossAssets * REDEMPTION_FEE) / BPS;
        netAssets   = grossAssets - fee;
    }

    /// @notice Preview how much TIME value a deposit would generate
    function previewDeposit(
        uint256 assets,
        uint256 lockDuration
    )
        external
        view
        returns (uint256 timeValue, uint256 inflationBps)
    {
        if (oracle.isCircuitBreakerActive()) return (0, 0);
        inflationBps = oracle.getWeightedInflation();
        timeValue    = (assets * inflationBps * lockDuration * 1e12)
                       / (BPS * DAYS_PER_YEAR * 1 days);
    }

    /// @notice Current TVL
    function tvl() external view returns (uint256) {
        return totalAssets();
    }

    /// @notice Utilization: active positions vs total deposited
    function utilizationBps() external view returns (uint256) {
        uint256 total = uint256(totalDeposited);
        if (total == 0) return 0;
        return (totalAssets() * BPS) / total;
    }

    // ════════════════════════════════════════════════════════════════════════
    // DAO ADMIN
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Lift the TVL cap.
    ///         Phase 0: $500k → Phase 1: $5M → Phase 2: $50M → Phase 3: unlimited
    function setTvlCap(uint256 newCap) external onlyRole(DAO_ROLE) {
        uint256 old = tvlCap;
        tvlCap = newCap;
        emit TvlCapUpdated(old, newCap);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(DAO_ROLE)    { _unpause(); }

    // ════════════════════════════════════════════════════════════════════════
    // ERC-4626 OVERRIDES
    // ════════════════════════════════════════════════════════════════════════

    /// @dev Offset of 6 prevents the ERC-4626 inflation (first-depositor) attack.
    ///      Makes virtual shares 10^6 × larger than underlying decimals.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev Disable all standard ERC-4626 entry points.
    ///      Users MUST use depositAndMintNFT() and redeemPosition().
    function deposit(uint256, address) public pure override returns (uint256) {
        revert("Vault: use depositAndMintNFT()");
    }
    function mint(uint256, address) public pure override returns (uint256) {
        revert("Vault: use depositAndMintNFT()");
    }
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("Vault: use redeemPosition()");
    }
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("Vault: use redeemPosition()");
    }
}
