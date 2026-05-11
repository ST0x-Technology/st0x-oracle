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

/// @dev Error raised when the `PythOracleAdapterBeaconSetDeployer` address in
/// `LibProdDeploy` is unset (zero) on the current chain.
error PythBeaconSetDeployerNotSet();

/// @dev Error raised when the `MorphoProtocolAdapterBeaconSetDeployer` address
/// in `LibProdDeploy` is unset (zero) on the current chain.
error MorphoBeaconSetDeployerNotSet();

/// @dev Error raised when the `PassthroughProtocolAdapterBeaconSetDeployer`
/// address in `LibProdDeploy` is unset (zero) on the current chain.
error PassthroughBeaconSetDeployerNotSet();

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
    /// @notice Emitted when a new oracle and protocol adapter set is deployed.
    /// @param caller The direct on-chain caller of `newOracleAndProtocolAdapters`
    /// — typically the originating EOA, but if this contract is itself wrapped
    /// behind another deployer it will be that intermediate contract, not the
    /// EOA. Indexed so monitoring can filter by deployer.
    /// @param pythOracleAdapter The address of the new PythOracleAdapter proxy.
    /// @param morphoProtocolAdapter The address of the new MorphoProtocolAdapter proxy.
    /// @param passthroughProtocolAdapter The address of the new PassthroughProtocolAdapter proxy.
    event Deployment(
        address indexed caller,
        address indexed pythOracleAdapter,
        address indexed morphoProtocolAdapter,
        address passthroughProtocolAdapter
    );

    /// @notice Deploy oracle + all protocol adapters for a new vault.
    /// @param vault The ERC-4626 vault address.
    /// @param priceId The Pyth price feed ID for the underlying asset.
    /// @param maxAge Maximum acceptable price age in seconds.
    /// @param registry The oracle registry. Admin must call registry.setOracle() separately.
    /// @param pauseConfig Corporate-action auto-pause configuration — see
    /// SPEC § 16. To disable auto-pause entirely, set
    /// `pauseConfig.corporateActionsVault = address(0)` (other fields ignored).
    /// Setting only `actionTypeMask = 0` while keeping a non-zero
    /// corporateActionsVault costs gas on every read but never pauses.
    // slither-disable-next-line reentrancy-events
    function newOracleAndProtocolAdapters(
        address vault,
        bytes32 priceId,
        uint256 maxAge,
        OracleRegistry registry,
        CorporateActionPauseConfig calldata pauseConfig
    ) external {
        // Pre-flight: every LibProdDeploy sub-deployer address must be set on
        // the current chain. Surface a typed error so a partial deployment or
        // wrong-chain invocation fails loudly rather than reverting deep
        // inside an ABI decode of an empty extcall return.
        if (LibProdDeploy.PYTH_ORACLE_ADAPTER_BEACON_SET_DEPLOYER == address(0)) {
            revert PythBeaconSetDeployerNotSet();
        }
        if (LibProdDeploy.MORPHO_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER == address(0)) {
            revert MorphoBeaconSetDeployerNotSet();
        }
        if (LibProdDeploy.PASSTHROUGH_PROTOCOL_ADAPTER_BEACON_SET_DEPLOYER == address(0)) {
            revert PassthroughBeaconSetDeployerNotSet();
        }

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
