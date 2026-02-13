// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";

/// @title LibProdOracles
/// @notice Hardcoded production oracle addresses deployed via
/// OracleUnifiedDeployer. Update these after each deployment.
library LibProdOracles {
    /// wtCOIN oracle adapter (PythOracleAdapter proxy).
    /// Deployed to Base 2026-02-13.
    address constant WTCOIN_ORACLE = 0x9f0fc96fef8e62bffd35bdb76e7287a3e4aa57b0;

    /// wtCOIN Morpho protocol adapter.
    /// Deployed to Base 2026-02-13.
    address constant WTCOIN_MORPHO = 0xbe4fe57576e54595400195e6bc00002cb4ed232e;

    /// wtCOIN passthrough protocol adapter (Aave/Compound).
    /// Deployed to Base 2026-02-13.
    address constant WTCOIN_PASSTHROUGH = 0x2e73ef522e9369576bd5fc8f25bf2f0e4cc6b57e;

    /// wtCOIN ERC-4626 vault.
    address constant WTCOIN_VAULT = 0x5cDa0E1CA4ce2af96315f7F8963C85399c172204;

    /// COIN/USD Pyth price feed ID.
    /// https://www.pyth.network/developers/price-feed-ids
    bytes32 constant COIN_PRICE_ID = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;
}

/// @title ProdForkTest
/// @notice Production fork tests for deployed st0x.oracle contracts on Base.
/// These tests run against real deployed contracts on a Base fork to verify
/// correct behavior with live Pyth prices and vault state.
///
/// To run: forge test --match-contract ProdForkTest --fork-url $RPC_URL_BASE_FORK
///
/// NOTE: Tests will be skipped (pass vacuously) until oracle addresses are
/// set in LibProdOracles. This allows the PR to merge before deployment.
contract ProdForkTest is Test {
    /// @dev Skip modifier for oracle-only tests.
    modifier onlyIfOracleDeployed() {
        if (LibProdOracles.WTCOIN_ORACLE == address(0)) {
            return;
        }
        _;
    }

    /// @dev Skip modifier for Morpho adapter tests.
    modifier onlyIfMorphoDeployed() {
        if (LibProdOracles.WTCOIN_MORPHO == address(0)) {
            return;
        }
        _;
    }

    /// @dev Skip modifier for Passthrough adapter tests.
    modifier onlyIfPassthroughDeployed() {
        if (LibProdOracles.WTCOIN_PASSTHROUGH == address(0)) {
            return;
        }
        _;
    }

    /// @dev Skip modifier for tests that require all three deployed.
    modifier onlyIfAllDeployed() {
        if (
            LibProdOracles.WTCOIN_ORACLE == address(0) || LibProdOracles.WTCOIN_MORPHO == address(0)
                || LibProdOracles.WTCOIN_PASSTHROUGH == address(0)
        ) {
            return;
        }
        _;
    }

    function _forkBase() internal {
        vm.createSelectFork(vm.envString("RPC_URL_BASE_FORK"));
    }

    // =========================================================================
    // PythOracleAdapter tests
    // =========================================================================

    /// @notice Oracle returns a positive price for wtCOIN.
    function testProdWtcoinOracleLatestAnswer() external onlyIfOracleDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        int256 answer = oracle.latestAnswer();

        // COIN trades roughly $50-$500. At 8 decimals that's 5e9 to 5e10.
        // Use wide bounds to be resilient to price moves.
        assertGt(answer, 1e9, "Price too low (< $10)");
        assertLt(answer, 1e12, "Price too high (> $10,000)");
    }

    /// @notice Oracle returns valid latestRoundData.
    function testProdWtcoinOracleLatestRoundData() external onlyIfOracleDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertGt(answer, 0, "Answer must be positive");
        assertGt(updatedAt, 0, "updatedAt must be set");
        // Price should not be older than maxAge (300s) + some fork tolerance
        assertGt(updatedAt, block.timestamp - 600, "Price too stale");
        assertEq(startedAt, updatedAt, "startedAt should equal updatedAt");
    }

    /// @notice Oracle reports 8 decimals.
    function testProdWtcoinOracleDecimals() external onlyIfOracleDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        assertEq(oracle.decimals(), 8);
    }

    /// @notice Oracle config matches expected values.
    function testProdWtcoinOracleConfig() external onlyIfOracleDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        assertEq(oracle.vault(), LibProdOracles.WTCOIN_VAULT, "Wrong vault");
        assertEq(oracle.priceId(), LibProdOracles.COIN_PRICE_ID, "Wrong priceId");
        assertEq(oracle.maxAge(), 300, "Expected 5 min maxAge");
        assertFalse(oracle.paused(), "Should not be paused");
    }

    /// @notice Oracle reverts when paused.
    function testProdWtcoinOracleRevertsWhenPaused() external onlyIfOracleDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        address oracleAdmin = oracle.admin();

        vm.prank(oracleAdmin);
        oracle.setPaused(true);

        vm.expectRevert();
        oracle.latestAnswer();

        // Unpause and verify it works again
        vm.prank(oracleAdmin);
        oracle.setPaused(false);

        int256 answer = oracle.latestAnswer();
        assertGt(answer, 0);
    }

    /// @notice Only admin can pause.
    function testProdWtcoinOracleOnlyAdminCanPause() external onlyIfOracleDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);

        vm.prank(address(0xdead));
        vm.expectRevert();
        oracle.setPaused(true);
    }

    // =========================================================================
    // MorphoProtocolAdapter tests
    // =========================================================================

    /// @notice Morpho adapter returns price scaled to 36 decimals.
    function testProdWtcoinMorphoPrice() external onlyIfMorphoDeployed {
        _forkBase();

        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MORPHO);
        uint256 morphoPrice = morpho.price();

        // Morpho scales 8 -> 36 decimals. COIN ~$50-$500 → 5e9 to 5e10 at 8 dec → 5e37 to 5e38 at 36 dec.
        assertGt(morphoPrice, 1e37, "Morpho price too low");
        assertLt(morphoPrice, 1e40, "Morpho price too high");
    }

    /// @notice Morpho adapter points to a valid registry and vault.
    function testProdWtcoinMorphoConfig() external onlyIfMorphoDeployed {
        _forkBase();

        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MORPHO);
        assertEq(morpho.vault(), LibProdOracles.WTCOIN_VAULT, "Morpho should reference the wtCOIN vault");
        assertTrue(address(morpho.registry()) != address(0), "Registry should be set");
    }

    // =========================================================================
    // PassthroughProtocolAdapter tests
    // =========================================================================

    /// @notice Passthrough adapter returns same answer as oracle.
    function testProdWtcoinPassthroughAnswer() external onlyIfPassthroughDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        int256 passthroughAnswer = passthrough.latestAnswer();

        assertGt(passthroughAnswer, 1e9, "Price too low");
        assertLt(passthroughAnswer, 1e12, "Price too high");
    }

    /// @notice Passthrough adapter returns valid roundData.
    function testProdWtcoinPassthroughRoundData() external onlyIfPassthroughDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        (, int256 ptAnswer,, uint256 ptUpdatedAt,) = passthrough.latestRoundData();

        assertGt(ptAnswer, 0, "Answer must be positive");
        assertGt(ptUpdatedAt, 0, "updatedAt must be set");
    }

    /// @notice Passthrough adapter reports 8 decimals.
    function testProdWtcoinPassthroughDecimals() external onlyIfPassthroughDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        assertEq(passthrough.decimals(), 8);
    }

    /// @notice Passthrough adapter points to a valid registry and vault.
    function testProdWtcoinPassthroughConfig() external onlyIfPassthroughDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        assertEq(passthrough.vault(), LibProdOracles.WTCOIN_VAULT, "Passthrough should reference the wtCOIN vault");
        assertTrue(address(passthrough.registry()) != address(0), "Registry should be set");
    }

    // =========================================================================
    // Cross-layer consistency
    // =========================================================================

    /// @notice All three contracts return consistent prices.
    function testProdWtcoinPriceConsistency() external onlyIfAllDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MORPHO);
        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);

        int256 oraclePrice = oracle.latestAnswer();
        int256 passthroughPrice = passthrough.latestAnswer();
        uint256 morphoPrice = morpho.price();

        // All three should be consistent
        assertEq(passthroughPrice, oraclePrice, "Passthrough != Oracle");
        assertEq(morphoPrice, uint256(oraclePrice) * 1e28, "Morpho != Oracle * 1e28");
    }

    // =========================================================================
    // Registry swap scenario
    // =========================================================================

    /// @notice Protocol adapters can swap registry reference.
    function testProdWtcoinSetRegistry() external onlyIfPassthroughDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        address ptAdmin = passthrough.admin();
        OracleRegistry currentRegistry = passthrough.registry();

        // Verify current registry works
        int256 answer = passthrough.latestAnswer();
        assertGt(answer, 0);

        // Only admin can set registry
        vm.prank(address(0xdead));
        vm.expectRevert();
        passthrough.setRegistry(currentRegistry);

        // Admin can set registry (set to same one, just testing the call works)
        vm.prank(ptAdmin);
        passthrough.setRegistry(currentRegistry);

        // Still works after re-setting
        int256 answerAfter = passthrough.latestAnswer();
        assertEq(answerAfter, answer);
    }
}
