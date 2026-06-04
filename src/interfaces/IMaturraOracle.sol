// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IMaturraOracle
/// @notice Interface for the MATURRA dual-source inflation oracle aggregator
interface IMaturraOracle {
    // ── ERRORS ────────────────────────────────────────────────────────────
    error StalePythData(uint256 age, uint256 maxAge);
    error StaleTruflationData(uint256 age, uint256 maxAge);
    error InvalidInflationRate(uint256 rate);
    error CircuitBreakerActive(uint256 frozenUntil);

    // ── EVENTS ───────────────────────────────────────────────────────────
    event InflationUpdated(
        uint256 indexed timestamp,
        uint256 truflationRate,
        uint256 pythRate,
        uint256 weightedRate
    );
    event CircuitBreakerTriggered(
        uint256 newRate,
        uint256 lastRate,
        uint256 divergence,
        uint256 frozenUntil
    );
    event WeightsUpdated(
        uint256 truflationWeight,
        uint256 pythWeight,
        uint256 effectiveAt
    );

    // ── VIEWS ────────────────────────────────────────────────────────────

    /// @notice Returns the current weighted inflation rate in basis points
    /// @dev    70% Truflation + 30% Pyth CPI. Reverts if data is stale.
    /// @return rate Inflation rate in basis points (228 = 2.28% annualized)
    function getWeightedInflation() external view returns (uint256 rate);

    /// @notice Returns individual source rates for transparency
    function getRawRates()
        external
        view
        returns (
            uint256 truflationRate,
            uint256 pythRate,
            uint256 truflationAge,  // seconds since last update
            uint256 pythAge         // seconds since last update
        );

    /// @notice Returns true if the circuit breaker is currently active
    function isCircuitBreakerActive() external view returns (bool);

    /// @notice Timestamp when circuit breaker will expire (0 if not active)
    function circuitBreakerExpiresAt() external view returns (uint256);

    /// @notice Current oracle weights (must sum to 100)
    function getWeights()
        external
        view
        returns (uint256 truflationWeight, uint256 pythWeight);
}
