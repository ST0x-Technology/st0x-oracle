// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {MultiPythOracleAdapterBeaconSetDeployer} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapterBeaconSetDeployer} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig
} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";

/// @dev Error raised when the MultiPythOracleAdapterBeaconSetDeployer is not
/// set in LibProdDeploy.
error MultiPythBeaconSetDeployerNotSet();

/// @title MultiOracleUnifiedDeployer
/// @notice Atomically deploys a MultiPythOracleAdapter and all protocol
/// adapters (Morpho, Passthrough for Aave/Compound) for a new vault. Mirrors
/// OracleUnifiedDeployer but uses multi-feed oracle for near-24/7 coverage.
contract MultiOracleUnifiedDeployer {
    /// Emitted when a new multi-feed oracle and protocol adapter set is deployed.
    event Deployment(
        address sender,
        address multiPythOracleAdapter,
        address morphoProtocolAdapter,
        address passthroughProtocolAdapter
    );

    /// @notice Deploy multi-feed oracle + all protocol adapters for a new vault.
    /// @param vault The ERC-4626 vault address.
    /// @param feeds Ordered list of Pyth feed configurations (tried in order).
    /// @param registry The oracle registry. Admin must call registry.setOracle() separately.
    /// @param pauseConfig Corporate-action auto-pause configuration — see
    /// SPEC § 16. Pass an all-zero struct to disable auto-pause (legacy /
    /// manual-only mode).
    // slither-disable-next-line reentrancy-events
    function newMultiOracleAndProtocolAdapters(
        address vault,
        FeedConfig[] calldata feeds,
        OracleRegistry registry,
        CorporateActionPauseConfig calldata pauseConfig
    ) external {
        if (LibProdDeploy.MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER == address(0)) {
            revert MultiPythBeaconSetDeployerNotSet();
        }

        // 1. Deploy multi-feed oracle adapter
        MultiPythOracleAdapter oracleAdapter = MultiPythOracleAdapterBeaconSetDeployer(
                LibProdDeploy.MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER
            )
            .newMultiPythOracleAdapter(
                MultiPythOracleAdapterConfig({vault: vault, feeds: feeds, admin: msg.sender, pauseConfig: pauseConfig})
            );

        // 2. Deploy Morpho protocol adapter
        MorphoProtocolAdapter morphoAdapter = MorphoProtocolAdapterBeaconSetDeployer(
                LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER
            ).newMorphoProtocolAdapter(registry, vault, msg.sender);

        // 3. Deploy passthrough protocol adapter (for Aave/Compound)
        PassthroughProtocolAdapter passthroughAdapter = PassthroughProtocolAdapterBeaconSetDeployer(
                LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER
            ).newPassthroughProtocolAdapter(registry, vault, msg.sender);

        emit Deployment(msg.sender, address(oracleAdapter), address(morphoAdapter), address(passthroughAdapter));
    }
}
