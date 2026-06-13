// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl }  from "@openzeppelin/contracts/access/AccessControl.sol";
import { IMaturraOracle }   from "./interfaces/IMaturraOracle.sol";
import { IPyth }            from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs }      from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

// ── EXTERNAL ORACLE INTERFACES ──────────────────────────────────────────────

/// @dev Truflation on-chain feed interface
interface ITruflationFeed {
    function getLatestInflation()
        external
        view
        returns (
            int256 value,       // inflation in 1e18 (e.g. 2.1e18 = 2.1%)
            uint256 updatedAt   // unix timestamp
        );
}

// ════════════════════════════════════════════════════════════════════════════
/// @title  MaturraOracle
/// @notice Dual-source inflation oracle aggregator for MATURRA Protocol.
///         Combines Truflation (70%) and Pyth Network CPI (30%) with
///         staleness guards, a circuit breaker, and DAO-adjustable weights.
///
/// @dev    All rates are expressed in BASIS POINTS (BPS) where 100 BPS = 1%.
///         e.g. 228 BPS = 2.28% annualized inflation.
///
///         Security model:
///         - Both sources must be fresh (<= STALENESS_LIMIT)
///         - Circuit breaker freezes on divergence > MAX_DIVERGENCE_BPS
///         - Weight changes require 48h timelock
///         - Neither source weight can fall below MIN_WEIGHT
// ════════════════════════════════════════════════════════════════════════════
contract MaturraOracle is IMaturraOracle, AccessControl {

    // ── ROLES ────────────────────────────────────────────────────────────────
    bytes32 public constant DAO_ROLE    = keccak256("DAO_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    // ── CONSTANTS ────────────────────────────────────────────────────────────
    uint256 public constant STALENESS_LIMIT     = 26 hours;
    // CPI data is published monthly — 40 days covers the longest release cycles
    uint256 public constant CPI_STALENESS_LIMIT = 40 days;
    uint256 public constant MAX_DIVERGENCE_BPS  = 150;  // 1.5%
    uint256 public constant FREEZE_DURATION     = 24 hours;
    uint256 public constant WEIGHT_TIMELOCK     = 48 hours;
    uint256 public constant MIN_WEIGHT          = 20;   // neither source < 20%
    uint256 public constant MAX_INFLATION_BPS   = 2000; // 20% sanity cap
    uint256 public constant WEIGHT_TOTAL        = 100;

    // ── PYTH FEED IDs ────────────────────────────────────────────────────────
    // ECO.US.CPIRATEY — US CPI 12-month change (annualized %)
    bytes32 public constant PYTH_CPI_ID =
        0x3c35e93113a975ab62428bcf92c6fa11d383438904aa38a79e506afac814688e;

    // ── STATE ────────────────────────────────────────────────────────────────
    ITruflationFeed public immutable truflationFeed;
    IPyth           public immutable pythFeed;

    // Weights — stored as integers summing to 100
    uint256 public truflationWeight = 70;
    uint256 public pythWeight       = 30;

    // Circuit breaker
    bool    public circuitBreakerActive;
    uint256 public circuitBreakerExpiry;
    uint256 public lastAcceptedRateBps;

    // Pending weight update (timelock)
    uint256 public pendingTruflationWeight;
    uint256 public pendingPythWeight;
    uint256 public weightUpdateReadyAt; // 0 = no pending update

    // ── CONSTRUCTOR ──────────────────────────────────────────────────────────
    constructor(
        address _truflationFeed,
        address _pythFeed,
        address _dao,
        address _keeper
    ) {
        require(_truflationFeed != address(0), "Oracle: zero truflation");
        require(_pythFeed       != address(0), "Oracle: zero pyth");
        require(_dao            != address(0), "Oracle: zero dao");

        truflationFeed = ITruflationFeed(_truflationFeed);
        pythFeed       = IPyth(_pythFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE,    _dao);
        _grantRole(KEEPER_ROLE, _keeper);
    }

    // ── CORE VIEW ────────────────────────────────────────────────────────────

    /// @inheritdoc IMaturraOracle
    function getWeightedInflation()
        external
        view
        override
        returns (uint256 rate)
    {
        // 1. Circuit breaker check
        if (circuitBreakerActive) {
            if (block.timestamp < circuitBreakerExpiry) {
                revert CircuitBreakerActive(circuitBreakerExpiry);
            }
            // Expired — will be cleared on next write (keeper)
        }

        // 2. Fetch and validate both sources
        (uint256 truflBps, uint256 truflAge) = _getTruflation();
        (uint256 pythBps,  uint256 pythAge)  = _getPythCPI();

        // 3. Staleness guards
        if (truflAge > STALENESS_LIMIT)
            revert StaleTruflationData(truflAge, STALENESS_LIMIT);
        if (pythAge > CPI_STALENESS_LIMIT)
            revert StalePythData(pythAge, CPI_STALENESS_LIMIT);

        // 4. Weighted average
        rate = (truflBps * truflationWeight + pythBps * pythWeight) / WEIGHT_TOTAL;

        // 5. Sanity cap — 20% annualized is the hard ceiling
        if (rate > MAX_INFLATION_BPS)
            revert InvalidInflationRate(rate);
    }

    /// @inheritdoc IMaturraOracle
    function getRawRates()
        external
        view
        override
        returns (
            uint256 truflationRate,
            uint256 pythRate,
            uint256 truflationAge,
            uint256 pythAge
        )
    {
        (truflationRate, truflationAge) = _getTruflation();
        (pythRate,       pythAge)       = _getPythCPI();
    }

    /// @inheritdoc IMaturraOracle
    function isCircuitBreakerActive() external view override returns (bool) {
        return circuitBreakerActive && block.timestamp < circuitBreakerExpiry;
    }

    /// @inheritdoc IMaturraOracle
    function circuitBreakerExpiresAt() external view override returns (uint256) {
        return circuitBreakerActive ? circuitBreakerExpiry : 0;
    }

    /// @inheritdoc IMaturraOracle
    function getWeights()
        external
        view
        override
        returns (uint256 tw, uint256 pw)
    {
        return (truflationWeight, pythWeight);
    }

    // ── KEEPER FUNCTIONS ─────────────────────────────────────────────────────

    /// @notice Validate current oracle state and clear expired circuit breaker.
    ///         Called by off-chain keeper bot after each CPI release.
    /// @dev    Emits InflationUpdated. Triggers circuit breaker if divergence
    ///         exceeds MAX_DIVERGENCE_BPS.
    function validateAndUpdate() external onlyRole(KEEPER_ROLE) {
        (uint256 truflBps, uint256 truflAge) = _getTruflation();
        (uint256 pythBps,  uint256 pythAge)  = _getPythCPI();

        require(truflAge <= STALENESS_LIMIT,     "Oracle: truflation stale");
        require(pythAge  <= CPI_STALENESS_LIMIT, "Oracle: pyth stale");

        uint256 newRate =
            (truflBps * truflationWeight + pythBps * pythWeight) / WEIGHT_TOTAL;

        require(newRate <= MAX_INFLATION_BPS, "Oracle: rate cap exceeded");

        // Clear expired circuit breaker
        if (circuitBreakerActive && block.timestamp >= circuitBreakerExpiry) {
            circuitBreakerActive = false;
        }

        // Check divergence vs last accepted rate
        if (lastAcceptedRateBps > 0) {
            uint256 divergence = _absDiff(newRate, lastAcceptedRateBps);
            if (divergence > MAX_DIVERGENCE_BPS) {
                // Trigger circuit breaker
                circuitBreakerActive  = true;
                circuitBreakerExpiry  = block.timestamp + FREEZE_DURATION;
                emit CircuitBreakerTriggered(
                    newRate,
                    lastAcceptedRateBps,
                    divergence,
                    circuitBreakerExpiry
                );
                return; // Do not update lastAcceptedRateBps
            }
        }

        lastAcceptedRateBps = newRate;
        emit InflationUpdated(block.timestamp, truflBps, pythBps, newRate);
    }

    // ── DAO FUNCTIONS ────────────────────────────────────────────────────────

    /// @notice Initiate a weight update with 48h timelock.
    ///         Weights must sum to 100 and each must be >= MIN_WEIGHT.
    function proposeWeightUpdate(
        uint256 newTruflationWeight,
        uint256 newPythWeight
    ) external onlyRole(DAO_ROLE) {
        require(
            newTruflationWeight + newPythWeight == WEIGHT_TOTAL,
            "Oracle: weights must sum to 100"
        );
        require(newTruflationWeight >= MIN_WEIGHT, "Oracle: truflation weight too low");
        require(newPythWeight       >= MIN_WEIGHT, "Oracle: pyth weight too low");

        pendingTruflationWeight = newTruflationWeight;
        pendingPythWeight       = newPythWeight;
        weightUpdateReadyAt     = block.timestamp + WEIGHT_TIMELOCK;

        emit WeightsUpdated(newTruflationWeight, newPythWeight, weightUpdateReadyAt);
    }

    /// @notice Execute a pending weight update after the timelock expires.
    function executeWeightUpdate() external onlyRole(DAO_ROLE) {
        require(weightUpdateReadyAt > 0, "Oracle: no pending update");
        require(block.timestamp >= weightUpdateReadyAt, "Oracle: timelock active");

        truflationWeight    = pendingTruflationWeight;
        pythWeight          = pendingPythWeight;
        weightUpdateReadyAt = 0;
    }

    /// @notice Emergency: manually clear circuit breaker (requires DAO multisig)
    function emergencyClearCircuitBreaker() external onlyRole(DAO_ROLE) {
        circuitBreakerActive = false;
        circuitBreakerExpiry = 0;
    }

    // ── INTERNAL ─────────────────────────────────────────────────────────────

    /// @dev Fetch Truflation rate and convert to BPS.
    ///      Truflation returns 1e18-scaled percentage (2.1e18 = 2.1%).
    function _getTruflation()
        internal
        view
        returns (uint256 rateBps, uint256 age)
    {
        (int256 rawValue, uint256 updatedAt) = truflationFeed.getLatestInflation();

        // Truflation can theoretically return negative during deflation
        // We floor at 0 — MATURRA does not negative-mint
        uint256 absValue = rawValue > 0 ? uint256(rawValue) : 0;

        // Convert from 1e18 percentage to BPS: 2.1e18 -> 210 BPS
        // rateBps = absValue * 100 / 1e18
        rateBps = absValue / 1e16;

        age = block.timestamp > updatedAt
            ? block.timestamp - updatedAt
            : 0;
    }

    /// @dev Fetch Pyth CPI rate and convert to BPS.
    ///      Pyth returns a Price struct with expo (e.g. price=270, expo=-2 = 2.70%).
    ///      CPI data is monthly so we allow up to CPI_STALENESS_LIMIT (40 days).
    function _getPythCPI()
        internal
        view
        returns (uint256 rateBps, uint256 age)
    {
        // Request price no older than CPI_STALENESS_LIMIT (monthly data)
        PythStructs.Price memory p = pythFeed.getPriceNoOlderThan(
            PYTH_CPI_ID,
            CPI_STALENESS_LIMIT
        );

        // Convert Pyth price to BPS
        // price=270, expo=-2 => 270 * 10^(-2) = 2.70% => 270 BPS
        // We standardize to BPS (2 decimal places for percentage)
        uint256 rawPrice = p.price > 0 ? uint256(int256(p.price)) : 0;
        int32   expo     = p.expo;

        if (expo >= -2) {
            // price already in BPS or needs scaling up
            rateBps = rawPrice * (10 ** uint32(expo + 2));
        } else {
            // Scale down: expo < -2
            rateBps = rawPrice / (10 ** uint32(-(expo + 2)));
        }

        age = block.timestamp > p.publishTime
            ? block.timestamp - p.publishTime
            : 0;
    }

    /// @dev Absolute difference between two uint256 values
    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
