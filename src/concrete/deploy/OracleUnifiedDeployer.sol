// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythOracleAdapterBeaconSetDeployer} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapterBeaconSetDeployer} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "src/concrete/oracle/PythOracleAdapter.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {LibProdDeploy} from "src/lib/LibProdDeploy.sol";

/// @title OracleUnifiedDeployer
/// @notice Atomically deploys a PythOracleAdapter and all protocol adapters
/// (Morpho, Passthrough for Aave/Compound) for a new vault. The beacon set
/// deployer addresses are hardcoded to simplify and harden deployment by
/// providing an audit trail in git of any address modifications.
/// @dev The sub-deployer addresses (`LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER`,
/// `LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER`,
/// `LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER`) are
/// inlined into this contract's runtime bytecode at compile time.
/// Redeploying any sub-deployer requires redeploying this contract too —
/// otherwise calls route to the old sub-deployer until this bytecode is
/// replaced. There is no on-chain pointer to chase. Tracked at #209.
contract OracleUnifiedDeployer {
    /// Emitted when a new oracle and protocol adapter set is deployed.
    event Deployment(
        address sender, address pythOracleAdapter, address morphoProtocolAdapter, address passthroughProtocolAdapter
    );

    /// @notice Deploy oracle + all protocol adapters for a new vault.
    /// @param vault The ERC-4626 vault address.
    /// @param priceId The Pyth price feed ID for the underlying asset.
    /// @param maxAge Maximum acceptable price age in seconds.
    /// @param registry The oracle registry. Admin must call registry.setOracle() separately.
    /// @param pauseConfig Corporate-action auto-pause configuration — see
    /// SPEC § 16. Pass an all-zero struct to disable auto-pause (legacy /
    /// manual-only mode).
    // slither-disable-next-line reentrancy-events
    function newOracleAndProtocolAdapters(
        address vault,
        bytes32 priceId,
        uint256 maxAge,
        OracleRegistry registry,
        CorporateActionPauseConfig calldata pauseConfig
    ) external {
        // 1. Deploy oracle adapter
        PythOracleAdapter oracleAdapter = PythOracleAdapterBeaconSetDeployer(
                LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER
            )
            .newPythOracleAdapter(
                PythOracleAdapterConfig({
                vault: vault, priceId: priceId, maxAge: maxAge, admin: msg.sender, pauseConfig: pauseConfig
            })
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
