// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { MaturraOracle }  from "../src/MaturraOracle.sol";
import { IPyth }          from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import { PythStructs }    from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

// Minimal Truflation stub — returns fresh 2.28% data
contract ForkMockTruflation {
    function getLatestInflation() external view returns (int256, uint256) {
        return (228e16, block.timestamp); // 228e16 = 2.28e18 = 2.28% -> 228 BPS
    }
}

// ════════════════════════════════════════════════════════════════════════════
/// @title  PythForkTest
/// @notice Fork Base Sepolia to verify that MaturraOracle correctly reads and
///         converts the real Pyth CPI feed (ECO.US.CPIRATEY).
///
/// @dev    Pyth uses a pull model: price data is stored on-chain only after
///         an off-chain VAA is submitted. On testnet the feed may be stale,
///         so we use vm.mockCall to inject a fresh price for integration tests
///         while still verifying the real contract is reachable (test 1).
// ════════════════════════════════════════════════════════════════════════════
contract PythForkTest is Test {

    // Real Pyth contract on Base Sepolia
    // Source: https://docs.pyth.network/price-feeds/contract-addresses/evm
    address constant PYTH_BASE_SEPOLIA = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    // ECO.US.CPIRATEY — US CPI 12-month change (annualized %)
    bytes32 constant CPI_FEED_ID =
        0x3c35e93113a975ab62428bcf92c6fa11d383438904aa38a79e506afac814688e;

    address dao    = makeAddr("dao");
    address keeper = makeAddr("keeper");

    MaturraOracle        oracle;
    ForkMockTruflation   truflation;

    function setUp() public {
        vm.createSelectFork("base_sepolia");
        truflation = new ForkMockTruflation();
        oracle = new MaturraOracle(
            address(truflation),
            PYTH_BASE_SEPOLIA,
            dao,
            keeper
        );
    }

    // ── 1. Sanity: real Pyth contract is deployed and responsive ────────────

    /// @notice Confirms the Pyth contract has code on Base Sepolia.
    ///         Macro feeds (CPI) are not pushed to testnet by Pyth — only mainnet
    ///         receives them via Hermes VAAs — so PriceFeedNotFound is expected.
    ///         Any other revert is a genuine failure.
    function test_pyth_contract_exists_and_responds() public {
        assertGt(PYTH_BASE_SEPOLIA.code.length, 0, "Pyth contract must be deployed");

        IPyth pyth = IPyth(PYTH_BASE_SEPOLIA);
        bytes4 notFound = bytes4(keccak256("PriceFeedNotFound()"));

        try pyth.getPriceUnsafe(CPI_FEED_ID) returns (PythStructs.Price memory p) {
            console2.log("CPI feed found on testnet:");
            console2.log("  publishTime:", p.publishTime);
            console2.log("  price      :", p.price);
            console2.log("  expo       :", p.expo);
            assertGt(p.publishTime, 0, "Feed must have a non-zero publishTime");
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertEq(selector, notFound, "Unexpected revert - check feed ID or contract address");
            console2.log("CPI feed not pushed to Base Sepolia (expected - macro feeds are mainnet only)");
        }
    }

    // ── 2. BPS conversion: expo=-2, price=410 (= 4.10%) ────────────────────

    /// @notice price=410, expo=-2  =>  410 * 10^(-2+2) = 410 BPS (4.10%)
    function test_bps_conversion_expo_minus2() public {
        _mockPythPrice(410, -2);
        (, uint256 pythRate,,) = oracle.getRawRates();
        assertEq(pythRate, 410, "410 * 10^0 = 410 BPS");
    }

    // ── 3. BPS conversion: expo=-4, price=41000 (= 4.10%) ──────────────────

    /// @notice price=41000, expo=-4  =>  41000 / 10^(4-2) = 41000 / 100 = 410 BPS
    function test_bps_conversion_expo_minus4() public {
        _mockPythPrice(41000, -4);
        (, uint256 pythRate,,) = oracle.getRawRates();
        assertEq(pythRate, 410, "41000 / 100 = 410 BPS");
    }

    // ── 4. BPS conversion: expo=0, price=4 (= 4.00%) ───────────────────────

    /// @notice price=4, expo=0  =>  4 * 10^(0+2) = 400 BPS (4.00%)
    function test_bps_conversion_expo_zero() public {
        _mockPythPrice(4, 0);
        (, uint256 pythRate,,) = oracle.getRawRates();
        assertEq(pythRate, 400, "4 * 100 = 400 BPS");
    }

    // ── 5. Full weighted inflation end-to-end ───────────────────────────────

    /// @notice Truflation = 228 BPS (2.28%), Pyth = 410 BPS (4.10%)
    ///         Expected: (228*70 + 410*30) / 100 = 28260 / 100 = 282 BPS
    function test_weighted_inflation_end_to_end() public {
        _mockPythPrice(410, -2);

        uint256 rate = oracle.getWeightedInflation();
        console2.log("Weighted inflation (BPS):", rate);

        // 228*70=15960, 410*30=12300, sum=28260, /100=282
        assertEq(rate, 282, "Weighted rate should be 282 BPS");
    }

    // ── 6. CPI staleness constants ───────────────────────────────────────────

    function test_staleness_constants() public view {
        assertEq(oracle.CPI_STALENESS_LIMIT(), 40 days,  "CPI limit = 40 days");
        assertEq(oracle.STALENESS_LIMIT(),     26 hours, "Truflation limit = 26h");
    }

    // ── 7. Negative / zero Pyth price floors to 0 BPS ───────────────────────

    function test_negative_pyth_price_floors_to_zero() public {
        _mockPythPriceRaw(-100, -2);
        (, uint256 pythRate,,) = oracle.getRawRates();
        assertEq(pythRate, 0, "Negative price should floor to 0 BPS");
    }

    // ── HELPERS ──────────────────────────────────────────────────────────────

    function _mockPythPrice(int64 price, int32 expo) internal {
        _mockPythPriceRaw(price, expo);
    }

    function _mockPythPriceRaw(int64 price, int32 expo) internal {
        PythStructs.Price memory p = PythStructs.Price({
            price:       price,
            conf:        5,
            expo:        expo,
            publishTime: block.timestamp - 1 hours
        });

        vm.mockCall(
            PYTH_BASE_SEPOLIA,
            abi.encodeWithSelector(
                IPyth.getPriceNoOlderThan.selector,
                CPI_FEED_ID,
                oracle.CPI_STALENESS_LIMIT()
            ),
            abi.encode(p)
        );
    }
}
