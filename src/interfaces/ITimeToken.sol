// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  ITimeToken
/// @notice Interface for the $TIME maturraral value token
interface ITimeToken is IERC20 {
    // ── STRUCTS ───────────────────────────────────────────────────────────
    struct LockMetadata {
        uint256 lockDuration;     // original lock in seconds
        uint256 inflationRateBps; // inflation rate at mint in basis points
        uint256 mintedAt;         // timestamp of mint
        uint256 maturesAt;        // timestamp when underlying unlocks
        uint256 originalAssets;   // underlying asset amount (6 decimals for USDC)
    }

    // ── ERRORS ────────────────────────────────────────────────────────────
    error OnlyVault();
    error TokenNotMatured(uint256 maturesAt, uint256 currentTime);
    error ZeroAmount();

    // ── EVENTS ───────────────────────────────────────────────────────────
    event TimeMinted(
        address indexed to,
        uint256 amount,
        uint256 lockDuration,
        uint256 inflationRateBps,
        uint256 maturesAt
    );
    event TimeRedeemed(
        address indexed by,
        uint256 timeAmount,
        uint256 assetsReturned
    );

    // ── VAULT ONLY ───────────────────────────────────────────────────────

    /// @notice Mint $TIME tokens with embedded lock metadata
    /// @param  to              Recipient address
    /// @param  amount          Amount of $TIME tokens (18 decimals)
    /// @param  lockDuration    Lock period in seconds
    /// @param  inflationRateBps Inflation rate used for calculation in BPS
    /// @param  originalAssets  Underlying asset amount (USDC 6 decimals)
    function mint(
        address to,
        uint256 amount,
        uint256 lockDuration,
        uint256 inflationRateBps,
        uint256 originalAssets
    ) external;

    /// @notice Burn $TIME tokens at redemption
    /// @dev    Only callable by vault after maturity check
    function burn(address from, uint256 amount) external;

    // ── VIEWS ────────────────────────────────────────────────────────────

    /// @notice Get lock metadata for a specific holder
    /// @dev    Returns the metadata from their most recent mint position
    function getLockMetadata(address holder)
        external
        view
        returns (LockMetadata memory);

    /// @notice Current time decay factor for a holder's position (0-10000 BPS)
    /// @dev    10000 = full value (just minted), 0 = matured
    function getTimeDecayFactor(address holder)
        external
        view
        returns (uint256 factorBps);

    /// @notice Total $TIME ever minted (for analytics)
    function totalMinted() external view returns (uint256);

    /// @notice Total $TIME ever burned (for analytics)
    function totalBurned() external view returns (uint256);
}
