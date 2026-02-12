// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";

/// @title LibProdOracles
/// @notice Hardcoded production oracle addresses deployed via
/// OracleUnifiedDeployer. Update these after each deployment.
library LibProdOracles {
    /// wtCOIN oracle adapter (PythOracleAdapter proxy).
    /// TODO: Set after deployment.
    address constant WTCOIN_ORACLE = address(0);

    /// wtCOIN Morpho protocol adapter.
    /// TODO: Set after deployment.
    address constant WTCOIN_MORPHO = address(0);

    /// wtCOIN passthrough protocol adapter (Aave/Compound).
    /// TODO: Set after deployment.
    address constant WTCOIN_PASSTHROUGH = address(0);

    /// wtCOIN ERC-4626 vault.
    address constant WTCOIN_VAULT = 0x5cDa0E1CA4ce2af96315f7F8963C85399c172204;

    /// COIN/USD Pyth price feed ID.
    /// https://www.pyth.network/developers/price-feed-ids
    bytes32 constant COIN_PRICE_ID = 0xe65ff435be2e5170520bca5af8e56241d18a8abe0e12face633cee71a685e08d;
}

/// @title ProdForkTest
/// @notice Production fork tests for deployed st0x.oracle contracts on Base.
/// These tests run against real deployed contracts on a Base fork to verify
/// correct behavior with live Pyth prices and vault state.
///
/// To run: forge test --match-contract ProdForkTest --fork-url $RPC_URL_BASE
///
/// NOTE: Tests will be skipped (pass vacuously) until oracle addresses are
/// set in LibProdOracles. This allows the PR to merge before deployment.
contract ProdForkTest is Test {
    /// @dev Skip modifier for tests that require deployed oracles.
    /// Remove once addresses are populated.
    modifier onlyIfDeployed() {
        if (LibProdOracles.WTCOIN_ORACLE == address(0)) {
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
    function testProdWtcoinOracleLatestAnswer() external onlyIfDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        int256 answer = oracle.latestAnswer();

        // COIN trades roughly $50-$500. At 8 decimals that's 5e9 to 5e10.
        // Use wide bounds to be resilient to price moves.
        assertGt(answer, 1e9, "Price too low (< $10)");
        assertLt(answer, 1e12, "Price too high (> $10,000)");
    }

    /// @notice Oracle returns valid latestRoundData.
    function testProdWtcoinOracleLatestRoundData() external onlyIfDeployed {
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
    function testProdWtcoinOracleDecimals() external onlyIfDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        assertEq(oracle.decimals(), 8);
    }

    /// @notice Oracle config matches expected values.
    function testProdWtcoinOracleConfig() external onlyIfDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        assertEq(oracle.vault(), LibProdOracles.WTCOIN_VAULT, "Wrong vault");
        assertEq(oracle.priceId(), LibProdOracles.COIN_PRICE_ID, "Wrong priceId");
        assertEq(oracle.maxAge(), 300, "Expected 5 min maxAge");
        assertFalse(oracle.paused(), "Should not be paused");
    }

    /// @notice Oracle reverts when paused.
    function testProdWtcoinOracleRevertsWhenPaused() external onlyIfDeployed {
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
    function testProdWtcoinOracleOnlyAdminCanPause() external onlyIfDeployed {
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
    function testProdWtcoinMorphoPrice() external onlyIfDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MORPHO);

        int256 oracleAnswer = oracle.latestAnswer();
        uint256 morphoPrice = morpho.price();

        // Morpho scales 8 -> 36 decimals (multiply by 1e28)
        assertEq(morphoPrice, uint256(oracleAnswer) * 1e28, "Morpho price should be oracle * 1e28");
    }

    /// @notice Morpho adapter points to the correct oracle.
    function testProdWtcoinMorphoOracleRef() external onlyIfDeployed {
        _forkBase();

        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MORPHO);
        assertEq(
            address(morpho.oracle()), LibProdOracles.WTCOIN_ORACLE, "Morpho should reference the wtCOIN oracle"
        );
    }

    // =========================================================================
    // PassthroughProtocolAdapter tests
    // =========================================================================

    /// @notice Passthrough adapter returns same answer as oracle.
    function testProdWtcoinPassthroughAnswer() external onlyIfDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);

        int256 oracleAnswer = oracle.latestAnswer();
        int256 passthroughAnswer = passthrough.latestAnswer();

        assertEq(passthroughAnswer, oracleAnswer, "Passthrough should match oracle exactly");
    }

    /// @notice Passthrough adapter returns same roundData as oracle.
    function testProdWtcoinPassthroughRoundData() external onlyIfDeployed {
        _forkBase();

        PythOracleAdapter oracle = PythOracleAdapter(LibProdOracles.WTCOIN_ORACLE);
        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);

        (, int256 oracleAnswer,, uint256 oracleUpdatedAt,) = oracle.latestRoundData();
        (, int256 ptAnswer,, uint256 ptUpdatedAt,) = passthrough.latestRoundData();

        assertEq(ptAnswer, oracleAnswer, "Answers must match");
        assertEq(ptUpdatedAt, oracleUpdatedAt, "Timestamps must match");
    }

    /// @notice Passthrough adapter reports 8 decimals.
    function testProdWtcoinPassthroughDecimals() external onlyIfDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        assertEq(passthrough.decimals(), 8);
    }

    /// @notice Passthrough adapter points to the correct oracle.
    function testProdWtcoinPassthroughOracleRef() external onlyIfDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        assertEq(
            address(passthrough.oracle()),
            LibProdOracles.WTCOIN_ORACLE,
            "Passthrough should reference the wtCOIN oracle"
        );
    }

    // =========================================================================
    // Cross-layer consistency
    // =========================================================================

    /// @notice All three contracts return consistent prices.
    function testProdWtcoinPriceConsistency() external onlyIfDeployed {
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
    // Protocol adapter setOracle (oracle swap scenario)
    // =========================================================================

    /// @notice Protocol adapters can swap oracle reference.
    function testProdWtcoinSetOracle() external onlyIfDeployed {
        _forkBase();

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);
        address ptAdmin = passthrough.admin();

        // Create a mock oracle that returns a known value
        address mockOracle = address(new MockAggregator(42e8));

        vm.prank(ptAdmin);
        passthrough.setOracle(AggregatorV3Interface(mockOracle));

        assertEq(passthrough.latestAnswer(), 42e8, "Should use new oracle");

        // Swap back
        vm.prank(ptAdmin);
        passthrough.setOracle(AggregatorV3Interface(LibProdOracles.WTCOIN_ORACLE));
    }
}

/// @dev Minimal mock for testing setOracle.
contract MockAggregator is AggregatorV3Interface {
    int256 private immutable _answer;

    constructor(int256 answer) {
        _answer = answer;
    }

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestAnswer() external view override returns (int256) {
        return _answer;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}
