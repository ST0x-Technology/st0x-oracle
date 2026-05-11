// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {AggregatorV2V3Interface} from "st0x.oracle/interface/IAggregatorV2V3.sol";
import {PythOracleAdapter} from "st0x.oracle/concrete/oracle/PythOracleAdapter.sol";
import {MultiPythOracleAdapter} from "st0x.oracle/concrete/oracle/MultiPythOracleAdapter.sol";
import {MorphoProtocolAdapter} from "st0x.oracle/concrete/protocol/MorphoProtocolAdapter.sol";
import {PassthroughProtocolAdapter} from "st0x.oracle/concrete/protocol/PassthroughProtocolAdapter.sol";
import {OracleRegistry, ZeroOracle, ArrayLengthMismatch} from "st0x.oracle/concrete/registry/OracleRegistry.sol";
import {LibProdDeploy} from "st0x.oracle/lib/LibProdDeploy.sol";
import {OraclePausedManual} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {OnlyAdmin, ZeroVault} from "st0x.oracle/lib/LibOracleErrors.sol";

/// @title LibProdOracles
/// @notice Hardcoded production oracle addresses deployed via
/// OracleUnifiedDeployer. Update these after each deployment.
library LibProdOracles {
    /// wtCOIN oracle adapter (PythOracleAdapter proxy).
    /// Deployed to Base 2026-02-13.
    address constant WTCOIN_ORACLE = 0x9f0fc96FeF8e62bfFD35bDb76e7287A3E4aa57B0;

    /// wtCOIN Morpho protocol adapter.
    /// Deployed to Base 2026-02-13.
    address constant WTCOIN_MORPHO = 0xbe4fE57576e54595400195e6bc00002CB4ed232E;

    /// wtCOIN passthrough protocol adapter (Aave/Compound).
    /// Deployed to Base 2026-02-13.
    address constant WTCOIN_PASSTHROUGH = 0x2e73ef522E9369576bD5fC8f25Bf2f0E4cC6b57E;

    /// wtCOIN ERC-4626 vault.
    address constant WTCOIN_VAULT = 0x5cDa0E1CA4ce2af96315f7F8963C85399c172204;

    /// COIN/USD Pyth price feed ID.
    /// https://www.pyth.network/developers/price-feed-ids
    bytes32 constant COIN_PRICE_ID = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;

    /// wtCOIN multi-feed oracle adapter (MultiPythOracleAdapter proxy).
    /// Deployed to Base 2026-02-19. Tx: 0xd2c62b2a.
    address constant WTCOIN_MULTI_ORACLE = 0x1C63889a9FAd36C6a4422B3dAFCD57b11deC73d8;

    /// wtCOIN multi-feed Morpho protocol adapter.
    /// Deployed to Base 2026-02-19. Tx: 0xd2c62b2a.
    address constant WTCOIN_MULTI_MORPHO = 0x9e775f2aB11E49E18924379A31502A8B593bBec7;

    /// wtCOIN multi-feed passthrough protocol adapter.
    /// Deployed to Base 2026-02-19. Tx: 0xd2c62b2a.
    address constant WTCOIN_MULTI_PASSTHROUGH = 0x2F179Ee0F7ec2767C48e6c43fb6f0C7c715b5880;
}

/// @title ProdForkTest
/// @notice Production fork tests for deployed st0x.oracle contracts on Base.
/// These tests run against real deployed contracts on a Base fork to verify
/// correct behavior with live Pyth prices and vault state.
///
/// To run: forge test --match-contract ProdForkTest --fork-url $RPC_URL_BASE_FORK
///
/// Tests in this contract use `vm.skip(true)` rather than silent `return;` when
/// the fork RPC env var (`RPC_URL_BASE_FORK`) is missing or a required prod
/// address is unset / has no code on the fork. This makes missing fork
/// availability surface as SKIPPED in `forge test` output (and in CI), rather
/// than as a vacuously-passing test with zero assertions.
contract ProdForkTest is Test {
    /// @dev Skip modifier for oracle-only tests.
    modifier onlyIfOracleDeployed() {
        if (LibProdOracles.WTCOIN_ORACLE == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Skip modifier for Morpho adapter tests.
    modifier onlyIfMorphoDeployed() {
        if (LibProdOracles.WTCOIN_MORPHO == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Skip modifier for Passthrough adapter tests.
    modifier onlyIfPassthroughDeployed() {
        if (LibProdOracles.WTCOIN_PASSTHROUGH == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Skip modifier for registry tests.
    modifier onlyIfRegistryDeployed() {
        if (LibProdDeploy.ORACLE_REGISTRY == address(0)) {
            vm.skip(true);
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
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev Fork Base at a specific block. Use FORK_BLOCK_BASE env var to pin
    /// to a block during NYSE market hours (required for COIN/USD Pyth feed).
    function _forkBase() internal {
        string memory rpc = vm.envString("RPC_URL_BASE_FORK");
        uint256 blockNumber = vm.envUint("FORK_BLOCK_BASE");
        vm.createSelectFork(rpc, blockNumber);
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

        // Accept either the legacy `OraclePaused()` selector (deployed mainnet
        // bytecode pre-corp-actions upgrade) or the post-rename
        // `OraclePausedManual()` (post-upgrade). Once the corp-actions stack
        // is deployed and mainnet bytecode reflects the rename, this can
        // tighten to the new selector only. Tracked via the mainnet redeploy
        // tasks (RAI-327 / RAI-328).
        (bool ok, bytes memory data) = address(oracle).staticcall(abi.encodeWithSelector(oracle.latestAnswer.selector));
        assertFalse(ok, "latestAnswer must revert while paused");
        require(data.length >= 4, "paused oracle must revert with a selector");
        bytes4 selector;
        assembly {
            selector := mload(add(data, 0x20))
        }
        bytes4 legacy = bytes4(keccak256("OraclePaused()"));
        assertTrue(
            selector == OraclePausedManual.selector || selector == legacy,
            "expected OraclePausedManual (new) or OraclePaused (legacy)"
        );

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
        vm.expectRevert(OnlyAdmin.selector);
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
    // OracleRegistry tests
    // =========================================================================

    /// @notice Registry has wtCOIN oracle registered.
    function testProdRegistryHasWtcoinOracle() external onlyIfRegistryDeployed onlyIfOracleDeployed {
        _forkBase();
        // Registry now points to multi oracle after swap; skip on post-swap fork blocks.
        if (_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        AggregatorV2V3Interface oracle = registry.getOracle(LibProdOracles.WTCOIN_VAULT);
        assertEq(address(oracle), LibProdOracles.WTCOIN_ORACLE, "Registry should map wtCOIN vault to oracle");
    }

    /// @notice Registry admin can update an oracle.
    function testProdRegistrySetOracle() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        address registryAdmin = registry.admin();

        // Set a dummy oracle for a dummy vault
        address dummyVault = address(0x1111111111111111111111111111111111111111);
        address dummyOracle = address(0x2222222222222222222222222222222222222222);

        vm.prank(registryAdmin);
        registry.setOracle(dummyVault, AggregatorV2V3Interface(dummyOracle));

        assertEq(address(registry.getOracle(dummyVault)), dummyOracle, "Oracle should be set");
    }

    /// @notice Registry admin can set oracles in bulk.
    function testProdRegistrySetOracleBulk() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        address registryAdmin = registry.admin();

        address[] memory vaults = new address[](3);
        vaults[0] = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
        vaults[1] = address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
        vaults[2] = address(0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC);

        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](3);
        oracles[0] = AggregatorV2V3Interface(address(0x1111111111111111111111111111111111111111));
        oracles[1] = AggregatorV2V3Interface(address(0x2222222222222222222222222222222222222222));
        oracles[2] = AggregatorV2V3Interface(address(0x3333333333333333333333333333333333333333));

        vm.prank(registryAdmin);
        registry.setOracleBulk(vaults, oracles);

        for (uint256 i = 0; i < vaults.length; i++) {
            assertEq(address(registry.getOracle(vaults[i])), address(oracles[i]), "Bulk oracle mismatch");
        }
    }

    /// @notice Non-admin cannot set oracles on the registry.
    function testProdRegistryOnlyAdminCanSetOracle() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);

        vm.prank(address(0xdead));
        vm.expectRevert(OnlyAdmin.selector);
        registry.setOracle(
            address(0x1111111111111111111111111111111111111111),
            AggregatorV2V3Interface(address(0x2222222222222222222222222222222222222222))
        );
    }

    /// @notice Non-admin cannot bulk set oracles.
    function testProdRegistryOnlyAdminCanSetOracleBulk() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);

        address[] memory vaults = new address[](1);
        vaults[0] = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](1);
        oracles[0] = AggregatorV2V3Interface(address(0x1111111111111111111111111111111111111111));

        vm.prank(address(0xdead));
        vm.expectRevert(OnlyAdmin.selector);
        registry.setOracleBulk(vaults, oracles);
    }

    /// @notice Bulk set with mismatched array lengths reverts.
    function testProdRegistryBulkMismatchedLengthsReverts() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        address registryAdmin = registry.admin();

        address[] memory vaults = new address[](2);
        vaults[0] = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
        vaults[1] = address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
        AggregatorV2V3Interface[] memory oracles = new AggregatorV2V3Interface[](1);
        oracles[0] = AggregatorV2V3Interface(address(0x1111111111111111111111111111111111111111));

        vm.prank(registryAdmin);
        vm.expectRevert(ArrayLengthMismatch.selector);
        registry.setOracleBulk(vaults, oracles);
    }

    /// @notice Setting zero vault reverts.
    function testProdRegistrySetOracleZeroVaultReverts() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        address registryAdmin = registry.admin();

        vm.prank(registryAdmin);
        vm.expectRevert(ZeroVault.selector);
        registry.setOracle(address(0), AggregatorV2V3Interface(address(0x1111111111111111111111111111111111111111)));
    }

    /// @notice Setting zero oracle reverts.
    function testProdRegistrySetOracleZeroOracleReverts() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        address registryAdmin = registry.admin();

        vm.prank(registryAdmin);
        vm.expectRevert(ZeroOracle.selector);
        registry.setOracle(address(0x1111111111111111111111111111111111111111), AggregatorV2V3Interface(address(0)));
    }

    /// @notice Admin can transfer admin role.
    function testProdRegistrySetAdmin() external onlyIfRegistryDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        address registryAdmin = registry.admin();
        address newAdmin = address(0x4444444444444444444444444444444444444444);

        vm.prank(registryAdmin);
        registry.setAdmin(newAdmin);
        assertEq(registry.admin(), newAdmin, "Admin should be updated");

        // New admin can act
        vm.prank(newAdmin);
        registry.setOracle(
            address(0x5555555555555555555555555555555555555555),
            AggregatorV2V3Interface(address(0x6666666666666666666666666666666666666666))
        );

        // Old admin cannot
        vm.prank(registryAdmin);
        vm.expectRevert(OnlyAdmin.selector);
        registry.setOracle(
            address(0x7777777777777777777777777777777777777777),
            AggregatorV2V3Interface(address(0x8888888888888888888888888888888888888888))
        );
    }

    /// @notice Registry oracle update propagates to protocol adapters.
    function testProdRegistryUpdatePropagates() external onlyIfRegistryDeployed onlyIfAllDeployed {
        _forkBase();

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MORPHO);
        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_PASSTHROUGH);

        // Get current price
        uint256 morphoPriceBefore = morpho.price();
        int256 ptPriceBefore = passthrough.latestAnswer();
        assertGt(morphoPriceBefore, 0);
        assertGt(ptPriceBefore, 0);

        // Swap the oracle in registry to a dummy — adapters should revert or return different data
        address registryAdmin = registry.admin();
        address dummyOracle = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);

        vm.prank(registryAdmin);
        registry.setOracle(LibProdOracles.WTCOIN_VAULT, AggregatorV2V3Interface(dummyOracle));

        // Adapters now point to dummy — dummy address has no code, so any
        // downstream view call into it reverts (either via Solidity's
        // abi.decode panic on empty return data, or via an
        // `UnexpectedOracleDecimals`-style guard if the adapter checks
        // first). We don't pin the exact revert payload — only that the
        // call fails — because the framing call (`oracle.decimals()`,
        // `oracle.latestAnswer()`, etc.) differs across adapter types
        // and across the optional decimal/staleness checks. Use raw
        // staticcall rather than `vm.expectRevert(bytes(""))` because
        // foundry-nightly panics decoding empty revert data under -vvv
        // verbosity (alloy-dyn-abi-1.5.2).
        (bool morphoOk,) = address(morpho).staticcall(abi.encodeWithSelector(morpho.price.selector));
        assertFalse(morphoOk, "Morpho price must revert when oracle has no code");

        (bool passOk,) = address(passthrough).staticcall(abi.encodeWithSelector(passthrough.latestAnswer.selector));
        assertFalse(passOk, "Passthrough latestAnswer must revert when oracle has no code");

        // Restore original oracle
        vm.prank(registryAdmin);
        registry.setOracle(LibProdOracles.WTCOIN_VAULT, AggregatorV2V3Interface(LibProdOracles.WTCOIN_ORACLE));

        // Should work again
        uint256 morphoPriceAfter = morpho.price();
        assertEq(morphoPriceAfter, morphoPriceBefore, "Price should be same after restore");
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
        vm.expectRevert(OnlyAdmin.selector);
        passthrough.setRegistry(currentRegistry);

        // Admin can set registry (set to same one, just testing the call works)
        vm.prank(ptAdmin);
        passthrough.setRegistry(currentRegistry);

        // Still works after re-setting
        int256 answerAfter = passthrough.latestAnswer();
        assertEq(answerAfter, answer);
    }

    // =========================================================================
    // MultiPythOracleAdapter prod tests
    // =========================================================================

    /// @dev Checks if a multi-feed address exists on the fork. Fork block may
    /// predate deployment, so we check code length after forking.
    function _existsOnFork(address addr) internal view returns (bool) {
        return addr != address(0) && addr.code.length > 0;
    }

    /// @notice Multi-feed oracle returns a positive price.
    function testProdWtcoinMultiOracleLatestAnswer() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        MultiPythOracleAdapter oracle = MultiPythOracleAdapter(LibProdOracles.WTCOIN_MULTI_ORACLE);
        int256 answer = oracle.latestAnswer();

        assertGt(answer, 1e9, "Price too low (< $10)");
        assertLt(answer, 1e12, "Price too high (> $10,000)");
    }

    /// @notice Multi-feed oracle returns valid latestRoundData.
    function testProdWtcoinMultiOracleLatestRoundData() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        MultiPythOracleAdapter oracle = MultiPythOracleAdapter(LibProdOracles.WTCOIN_MULTI_ORACLE);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();

        assertEq(roundId, 1);
        assertEq(answeredInRound, 1);
        assertGt(answer, 0, "Answer must be positive");
        assertGt(updatedAt, 0, "updatedAt must be set");
        assertGt(updatedAt, block.timestamp - 600, "Price too stale");
        assertEq(startedAt, updatedAt, "startedAt should equal updatedAt");
    }

    /// @notice Multi-feed oracle reports 8 decimals.
    function testProdWtcoinMultiOracleDecimals() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        MultiPythOracleAdapter oracle = MultiPythOracleAdapter(LibProdOracles.WTCOIN_MULTI_ORACLE);
        assertEq(oracle.decimals(), 8);
    }

    /// @notice Multi-feed oracle config: vault, feed count, not paused.
    function testProdWtcoinMultiOracleConfig() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        MultiPythOracleAdapter oracle = MultiPythOracleAdapter(LibProdOracles.WTCOIN_MULTI_ORACLE);
        assertEq(oracle.vault(), LibProdOracles.WTCOIN_VAULT, "Wrong vault");
        assertGt(oracle.feedCount(), 1, "Should have multiple feeds");
        assertFalse(oracle.paused(), "Should not be paused");
    }

    /// @notice Multi-feed oracle reverts when paused.
    function testProdWtcoinMultiOracleRevertsWhenPaused() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        MultiPythOracleAdapter oracle = MultiPythOracleAdapter(LibProdOracles.WTCOIN_MULTI_ORACLE);
        address oracleAdmin = oracle.admin();

        vm.prank(oracleAdmin);
        oracle.setPaused(true);

        vm.expectRevert(OraclePausedManual.selector);
        oracle.latestAnswer();

        vm.prank(oracleAdmin);
        oracle.setPaused(false);

        int256 answer = oracle.latestAnswer();
        assertGt(answer, 0);
    }

    /// @notice Multi-feed Morpho adapter returns price scaled to 36 decimals.
    function testProdWtcoinMultiMorphoPrice() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_MORPHO)) {
            vm.skip(true);
            return;
        }

        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MULTI_MORPHO);
        uint256 morphoPrice = morpho.price();

        assertGt(morphoPrice, 1e37, "Morpho price too low");
        assertLt(morphoPrice, 1e40, "Morpho price too high");
    }

    /// @notice Multi-feed passthrough returns same answer as multi-feed oracle.
    function testProdWtcoinMultiPassthroughAnswer() external {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_PASSTHROUGH)) {
            vm.skip(true);
            return;
        }

        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_MULTI_PASSTHROUGH);
        int256 answer = passthrough.latestAnswer();

        assertGt(answer, 1e9, "Price too low");
        assertLt(answer, 1e12, "Price too high");
    }

    /// @notice All three multi-feed contracts return consistent prices.
    function testProdWtcoinMultiPriceConsistency() external {
        _forkBase();
        if (
            !_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE) || !_existsOnFork(LibProdOracles.WTCOIN_MULTI_MORPHO)
                || !_existsOnFork(LibProdOracles.WTCOIN_MULTI_PASSTHROUGH)
        ) {
            vm.skip(true);
            return;
        }

        MultiPythOracleAdapter oracle = MultiPythOracleAdapter(LibProdOracles.WTCOIN_MULTI_ORACLE);
        MorphoProtocolAdapter morpho = MorphoProtocolAdapter(LibProdOracles.WTCOIN_MULTI_MORPHO);
        PassthroughProtocolAdapter passthrough = PassthroughProtocolAdapter(LibProdOracles.WTCOIN_MULTI_PASSTHROUGH);

        int256 oraclePrice = oracle.latestAnswer();
        int256 passthroughPrice = passthrough.latestAnswer();
        uint256 morphoPrice = morpho.price();

        assertEq(passthroughPrice, oraclePrice, "Passthrough != Oracle");
        assertEq(morphoPrice, uint256(oraclePrice) * 1e28, "Morpho != Oracle * 1e28");
    }

    /// @notice Multi-feed oracle registered in registry matches expected address.
    function testProdRegistryHasWtcoinMultiOracle() external onlyIfRegistryDeployed {
        _forkBase();
        if (!_existsOnFork(LibProdOracles.WTCOIN_MULTI_ORACLE)) {
            vm.skip(true);
            return;
        }

        OracleRegistry registry = OracleRegistry(LibProdDeploy.ORACLE_REGISTRY);
        AggregatorV2V3Interface oracle = registry.getOracle(LibProdOracles.WTCOIN_VAULT);
        // After multi-feed deployment, registry should point to the multi oracle.
        assertEq(address(oracle), LibProdOracles.WTCOIN_MULTI_ORACLE, "Registry should map to multi oracle");
    }
}
