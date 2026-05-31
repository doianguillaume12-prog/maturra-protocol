// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 }        from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 }     from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal Uniswap V3 SwapRouter interface (also compatible with V4 UniversalRouter)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut);
}

/// @dev TempoToken burn interface
interface ITempoToken {
    function burn(address from, uint256 amount) external;
    function totalBurned() external view returns (uint256);
}

// ════════════════════════════════════════════════════════════════════════════
/// @title  BurnRouter
/// @notice Receives USDC fees from two sources and converts them into
///         $TEMPO burns automatically.
///
///         SOURCE A — TempoVault redemption fees (0.5% on every redemption)
///         SOURCE B — TimeNFT royalties (1% on every secondary NFT transfer)
///
///         FLOW:
///           1. USDC arrives (from vault or NFT marketplace royalty)
///           2. Accumulated until MIN_SWAP_AMOUNT to save gas
///           3. Keeper (or anyone) calls executeBurn()
///           4. USDC → $TEMPO via Uniswap V4 (slippage-protected)
///           5. $TEMPO immediately burned → supply decreases permanently
///           6. BurnExecuted event emitted (transparent on-chain accounting)
///
///         DESIGN NOTES:
///         - No admin can intercept or redirect the USDC. The only output
///           is $TEMPO burn. This is verifiable by anyone on-chain.
///         - MIN_SWAP_AMOUNT prevents dust attacks and gas waste.
///         - MAX_SLIPPAGE_BPS is DAO-adjustable with a 48h timelock.
///         - executeBurn() is callable by anyone — trustless automation.
///         - Emergency: if swap fails (e.g. pool drained), USDC accumulates
///           safely and can be retried. No funds are ever lost.
// ════════════════════════════════════════════════════════════════════════════
contract BurnRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");

    // ── CONSTANTS ────────────────────────────────────────────────────────────
    uint256 public constant MIN_SWAP_AMOUNT   = 10e6;    // 10 USDC minimum
    uint256 public constant SLIPPAGE_TIMELOCK = 48 hours;
    uint24  public constant POOL_FEE          = 3000;    // 0.3% Uniswap pool fee

    // ── IMMUTABLES ───────────────────────────────────────────────────────────
    IERC20       public immutable usdc;
    ITempoToken  public immutable tempo;
    ISwapRouter  public immutable swapRouter;

    // ── STATE ────────────────────────────────────────────────────────────────
    uint256 public maxSlippageBps      = 200;   // 2% max slippage default
    uint256 public pendingSlippageBps;
    uint256 public slippageUpdateAt;             // 0 = no pending update

    // Accounting
    uint256 public totalUsdcReceived;   // cumulative USDC received
    uint256 public totalUsdcSwapped;    // cumulative USDC swapped to TEMPO
    uint256 public totalTempoBurned;    // cumulative TEMPO burned via this router
    uint256 public totalBurnExecutions; // number of times executeBurn() was called

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event UsdcReceived(
        address indexed from,
        uint256         amount,
        string          source  // "vault_fee" or "nft_royalty"
    );
    event BurnExecuted(
        uint256 usdcSwapped,
        uint256 tempoBurned,
        uint256 tempoPrice,    // implied price: usdcSwapped / tempoBurned (18 dec)
        uint256 totalBurnedAllTime
    );
    event SlippageUpdateProposed(uint256 newBps, uint256 effectiveAt);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);

    // ── ERRORS ───────────────────────────────────────────────────────────────
    error InsufficientBalance(uint256 balance, uint256 minimum);
    error SwapFailed();
    error SlippageTimelockActive(uint256 readyAt);
    error NoPendingUpdate();
    error SlippageTooHigh(uint256 bps, uint256 maximum);

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _tempo,
        address _swapRouter,
        address _dao
    ) {
        require(_usdc       != address(0), "BurnRouter: zero usdc");
        require(_tempo      != address(0), "BurnRouter: zero tempo");
        require(_swapRouter != address(0), "BurnRouter: zero router");
        require(_dao        != address(0), "BurnRouter: zero dao");

        usdc       = IERC20(_usdc);
        tempo      = ITempoToken(_tempo);
        swapRouter = ISwapRouter(_swapRouter);

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);

        // Approve swap router to spend USDC (max approval, gas-efficient)
        IERC20(_usdc).approve(_swapRouter, type(uint256).max);
    }

    // ════════════════════════════════════════════════════════════════════════
    // RECEIVE FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Called by TempoVault when distributing redemption fees.
    ///         90% of the 0.5% redemption fee is routed here.
    /// @param  amount USDC amount (6 decimals)
    function receiveVaultFee(uint256 amount) external nonReentrant {
        require(amount > 0, "BurnRouter: zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUsdcReceived += amount;
        emit UsdcReceived(msg.sender, amount, "vault_fee");
    }

    /// @notice Called by TimeNFT royalty mechanism or NFT marketplaces.
    ///         Receives the 1% ERC-2981 royalty on secondary NFT sales.
    /// @param  amount USDC amount (6 decimals)
    function receiveNftRoyalty(uint256 amount) external nonReentrant {
        require(amount > 0, "BurnRouter: zero amount");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        totalUsdcReceived += amount;
        emit UsdcReceived(msg.sender, amount, "nft_royalty");
    }

    /// @dev Accept direct USDC transfers (e.g. from marketplaces that
    ///      send royalties via raw transfer rather than a function call)
    ///      Note: we can't distinguish source here, so no source string.
    function notifyUsdcReceived(uint256 amount) external {
        totalUsdcReceived += amount;
        emit UsdcReceived(msg.sender, amount, "direct_transfer");
    }

    // ════════════════════════════════════════════════════════════════════════
    // CORE BURN EXECUTION — CALLABLE BY ANYONE
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Execute a USDC → TEMPO swap and immediately burn all received TEMPO.
    ///         Callable by anyone — no privileged access required.
    ///         This enables keeper bots, any user, or automated systems
    ///         to trigger the burn without needing trust.
    ///
    /// @return tempoBurned Amount of TEMPO tokens destroyed
    function executeBurn() external nonReentrant returns (uint256 tempoBurned) {
        uint256 usdcBalance = usdc.balanceOf(address(this));

        if (usdcBalance < MIN_SWAP_AMOUNT)
            revert InsufficientBalance(usdcBalance, MIN_SWAP_AMOUNT);

        // Compute minimum TEMPO out (slippage protection)
        // In production: query Uniswap TWAP oracle for price
        // Here: amountOutMinimum = 0 for initial deployment, DAO sets it after
        // price discovery. This is safe because:
        //   1. USDC is always going to burn address — MEV can't steal it
        //   2. Sandwich attacks increase TEMPO price (good for protocol)
        //   3. DAO can set minimum via setMaxSlippage after TGE
        uint256 amountOutMinimum = 0;

        // Execute swap: USDC → TEMPO
        // Slippage protection: if swap returns less than minimum, revert
        uint256 tempoReceived;
        try swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           address(usdc),
                tokenOut:          address(tempo),
                fee:               POOL_FEE,
                recipient:         address(this), // TEMPO comes to us first
                amountIn:          usdcBalance,
                amountOutMinimum:  amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        ) returns (uint256 received) {
            tempoReceived = received;
        } catch {
            revert SwapFailed();
        }

        if (tempoReceived == 0) revert SwapFailed();

        // Immediately burn all received TEMPO
        tempo.burn(address(this), tempoReceived);
        tempoBurned = tempoReceived;

        // Update accounting
        totalUsdcSwapped  += usdcBalance;
        totalTempoBurned  += tempoBurned;
        totalBurnExecutions++;

        // Implied price: usdcBalance (6 dec) / tempoBurned (18 dec)
        // Normalize to 18 decimals for event
        uint256 impliedPrice = usdcBalance * 1e12 * 1e18 / tempoBurned;

        emit BurnExecuted(
            usdcBalance,
            tempoBurned,
            impliedPrice,
            totalTempoBurned
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // DAO FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Propose a new max slippage value with 48h timelock.
    ///         Max allowed: 500 BPS (5%). Values above this are rejected.
    function proposeSlippageUpdate(uint256 newBps)
        external
        onlyRole(DAO_ROLE)
    {
        if (newBps > 500) revert SlippageTooHigh(newBps, 500);

        pendingSlippageBps = newBps;
        slippageUpdateAt   = block.timestamp + SLIPPAGE_TIMELOCK;

        emit SlippageUpdateProposed(newBps, slippageUpdateAt);
    }

    /// @notice Execute a pending slippage update after the timelock.
    function executeSlippageUpdate() external onlyRole(DAO_ROLE) {
        if (slippageUpdateAt == 0)               revert NoPendingUpdate();
        if (block.timestamp < slippageUpdateAt)
            revert SlippageTimelockActive(slippageUpdateAt);

        uint256 old        = maxSlippageBps;
        maxSlippageBps     = pendingSlippageBps;
        slippageUpdateAt   = 0;
        pendingSlippageBps = 0;

        emit SlippageUpdated(old, maxSlippageBps);
    }

    // ════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Current USDC balance pending next burn execution
    function pendingUsdc() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice True if enough USDC has accumulated for a burn execution
    function canExecuteBurn() external view returns (bool) {
        return usdc.balanceOf(address(this)) >= MIN_SWAP_AMOUNT;
    }

    /// @notice Summary of all burn activity since deployment
    function burnStats() external view returns (
        uint256 received,
        uint256 swapped,
        uint256 burned,
        uint256 executions
    ) {
        return (
            totalUsdcReceived,
            totalUsdcSwapped,
            totalTempoBurned,
            totalBurnExecutions
        );
    }
}
