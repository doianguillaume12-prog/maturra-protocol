// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 }           from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit }     from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes }      from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { AccessControl }   from "@openzeppelin/contracts/access/AccessControl.sol";
import { Nonces }          from "@openzeppelin/contracts/utils/Nonces.sol";

// ════════════════════════════════════════════════════════════════════════════
/// @title  MaturraToken
/// @notice The $MATURRA governance and value accrual token.
///
///         DESIGN PRINCIPLES (informed by post-mortem analysis of ve failures
///         and Hyperliquid's 93% fee redistribution model):
///
///         1. FIXED SUPPLY, NO INFLATION — 1,000,000,000 tokens minted once
///            at construction. No mint function. Supply can only decrease.
///
///         2. BURN-ONLY VALUE ACCRUAL — Value flows to holders via supply
///            compression, not dividends. This avoids security classification
///            risks that come with direct revenue sharing (Howey test).
///            Inspired by: Hyperliquid (93% of fees → buyback+burn),
///            BNB (quarterly burns), ETH post-EIP-1559.
///
///         3. GOVERNANCE VIA ERC20VOTES — OpenZeppelin Governor-compatible.
///            No ve-lock required. Simpler = more participation.
///            Any holder can delegate and vote.
///
///         4. BURN CALLERS — Only BurnRouter can call burn() programmatically.
///            Any holder can burn their own tokens (reduces supply further).
///            This prevents unauthorized destruction of protocol-owned supply.
///
///         5. TRANSPARENT ACCOUNTING — totalBurned() is public and permanent.
///            Every burn is an on-chain event. The community can verify the
///            deflation schedule in real time.
///
///         6. ERC20PERMIT — Gasless approvals. Users can authorize the vault
///            or market in a single tx via permit + deposit/buy. Better UX.
// ════════════════════════════════════════════════════════════════════════════
contract MaturraToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {

    // ── ROLES ────────────────────────────────────────────────────────────────
    /// @notice BurnRouter role — can call burn() on behalf of the protocol.
    ///         Granted only to BurnRouter.sol at deployment.
    bytes32 public constant BURN_ROUTER_ROLE = keccak256("BURN_ROUTER_ROLE");

    // ── SUPPLY ───────────────────────────────────────────────────────────────
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1 billion

    // ── BURN ACCOUNTING ──────────────────────────────────────────────────────
    uint256 private _totalBurned;

    // ── EVENTS ───────────────────────────────────────────────────────────────
    event Burned(
        address indexed burner,     // who initiated the burn
        address indexed from,       // whose tokens were burned
        uint256         amount,     // raw amount (18 dec)
        uint256         totalBurned // cumulative all-time
    );

    // ── ERRORS ───────────────────────────────────────────────────────────────
    error ZeroBurn();
    error BurnExceedsBalance(uint256 requested, uint256 balance);
    error OnlyBurnRouterOrSelf();

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    /// @param dao         DAO multisig — receives DEFAULT_ADMIN_ROLE
    /// @param burnRouter  BurnRouter contract — receives BURN_ROUTER_ROLE
    /// @param treasury    Receives the full initial supply for distribution
    constructor(
        address dao,
        address burnRouter,
        address treasury
    )
        ERC20("Maturra Protocol", "MATURRA")
        ERC20Permit("Maturra Protocol")
    {
        require(dao        != address(0), "MATURRA: zero dao");
        require(burnRouter != address(0), "MATURRA: zero burnRouter");
        require(treasury   != address(0), "MATURRA: zero treasury");

        _grantRole(DEFAULT_ADMIN_ROLE, dao);
        _grantRole(BURN_ROUTER_ROLE,   burnRouter);

        // Mint entire supply to treasury for controlled distribution
        // Treasury distributes per tokenomics schedule:
        //   35% Community, 15% POL, 15% Treasury ops, 20% Investors,
        //   8% Team, 5% Founder, 2% Bug bounty
        _mint(treasury, MAX_SUPPLY);
    }

    // ════════════════════════════════════════════════════════════════════════
    // BURN FUNCTIONS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Burn tokens from an account.
    ///         Callable by:
    ///           - BURN_ROUTER_ROLE (BurnRouter after swapping fees → MATURRA)
    ///           - The token holder themselves (voluntary burn)
    ///
    /// @param  from    Address whose tokens to burn
    /// @param  amount  Amount to burn (18 decimals)
    function burn(address from, uint256 amount) external {
        // Caller must be BurnRouter OR burning their own tokens
        bool isBurnRouter = hasRole(BURN_ROUTER_ROLE, msg.sender);
        bool isSelf       = msg.sender == from;

        if (!isBurnRouter && !isSelf) revert OnlyBurnRouterOrSelf();
        if (amount == 0)              revert ZeroBurn();

        uint256 balance = balanceOf(from);
        if (balance < amount)
            revert BurnExceedsBalance(amount, balance);

        // If BurnRouter is burning from its own balance (standard flow):
        // BurnRouter receives MATURRA from swap, then calls burn(address(this), amount)
        _burn(from, amount);

        _totalBurned += amount;

        emit Burned(msg.sender, from, amount, _totalBurned);
    }

    /// @notice Convenience: burn caller's own tokens
    function burnSelf(uint256 amount) external {
        if (amount == 0) revert ZeroBurn();
        _burn(msg.sender, amount);
        _totalBurned += amount;
        emit Burned(msg.sender, msg.sender, amount, _totalBurned);
    }

    // ════════════════════════════════════════════════════════════════════════
    // GOVERNANCE DELEGATION
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Delegate voting power to self (required before voting).
    ///         Call this once after receiving MATURRA tokens.
    function selfDelegate() external {
        _delegate(msg.sender, msg.sender);
    }

    // ════════════════════════════════════════════════════════════════════════
    // VIEWS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Total MATURRA burned since genesis. Only ever increases.
    function totalBurned() external view returns (uint256) {
        return _totalBurned;
    }

    /// @notice Circulating supply = totalSupply (since max supply was minted once)
    ///         Note: totalSupply() already reflects burns via ERC20._burn()
    function circulatingSupply() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice Percentage of max supply burned (in basis points, 0-10000)
    function burnedBps() external view returns (uint256) {
        return (_totalBurned * 10_000) / MAX_SUPPLY;
    }

    // ════════════════════════════════════════════════════════════════════════
    // REQUIRED OVERRIDES
    // ════════════════════════════════════════════════════════════════════════

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
