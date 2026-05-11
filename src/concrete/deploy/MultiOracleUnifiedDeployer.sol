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

/// @dev Error raised when the `MorphoProtocolAdapterBeaconSetDeployer` address
/// in `LibProdDeploy` is unset (zero) on the current chain.
error MorphoBeaconSetDeployerNotSet();

/// @dev Error raised when the `PassthroughProtocolAdapterBeaconSetDeployer`
/// address in `LibProdDeploy` is unset (zero) on the current chain.
error PassthroughBeaconSetDeployerNotSet();

/// @title MultiOracleUnifiedDeployer
/// @notice Atomically deploys a MultiPythOracleAdapter and all protocol
/// adapters (Morpho, Passthrough for Aave/Compound) for a new vault. Mirrors
/// OracleUnifiedDeployer (with an added pre-flight check that the multi-Pyth
/// beacon-set deployer constant in LibProdDeploy is non-zero) but uses
/// multi-feed oracle for near-24/7 coverage.
/// @dev The sub-deployer addresses
/// (`LibProdDeploy.MULTI_PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER`,
/// `LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER`,
/// `LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER`) are
/// inlined into this contract's runtime bytecode at compile time.
/// Redeploying any sub-deployer requires redeploying this contract too —
/// otherwise calls route to the old sub-deployer until this bytecode is
/// replaced. There is no on-chain pointer to chase. Tracked at #209.
contract MultiOracleUnifiedDeployer {
    /// @notice Emitted when a new multi-feed oracle and protocol adapter set is deployed.
    /// @param caller The direct on-chain caller of
    /// `newMultiOracleAndProtocolAdapters` — typically the originating EOA,
    /// but if this contract is itself wrapped behind another deployer it will
    /// be that intermediate contract, not the EOA. Indexed so monitoring can
    /// filter by deployer.
    /// @param multiPythOracleAdapter The address of the new MultiPythOracleAdapter proxy.
    /// @param morphoProtocolAdapter The address of the new MorphoProtocolAdapter proxy.
    /// @param passthroughProtocolAdapter The address of the new PassthroughProtocolAdapter proxy.
    event Deployment(
        address indexed caller,
        address indexed multiPythOracleAdapter,
        address indexed morphoProtocolAdapter,
        address passthroughProtocolAdapter
    );

    /// @notice Deploy multi-feed oracle + all protocol adapters for a new vault.
    /// @param vault The ERC-4626 vault address.
    /// @param feeds Ordered list of Pyth feed configurations (tried in order).
    /// @param registry The oracle registry. Admin must call registry.setOracle() separately.
    /// @param pauseConfig Corporate-action auto-pause configuration — see
    /// SPEC § 16. To disable auto-pause entirely, set
    /// `pauseConfig.corporateActionsVault = address(0)` (other fields ignored).
    /// Setting only `actionTypeMask = 0` while keeping a non-zero
    /// corporateActionsVault costs gas on every read but never pauses.
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
        if (LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER == address(0)) {
            revert MorphoBeaconSetDeployerNotSet();
        }
        if (LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER == address(0)) {
            revert PassthroughBeaconSetDeployerNotSet();
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
