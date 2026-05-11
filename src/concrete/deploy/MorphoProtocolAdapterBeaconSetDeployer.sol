// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {MorphoProtocolAdapter, MorphoProtocolAdapterConfig} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the protocol adapter fails.
error InitializeAdapterFailed();

/// @title MorphoProtocolAdapterBeaconSetDeployerConfig
/// @notice Configuration for the MorphoProtocolAdapterBeaconSetDeployer
/// construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialMorphoProtocolAdapterImplementation The initial implementation.
struct MorphoProtocolAdapterBeaconSetDeployerConfig {
    address initialOwner;
    address initialMorphoProtocolAdapterImplementation;
}

/// @title MorphoProtocolAdapterBeaconSetDeployer
/// @notice Deploys a beacon and the proxies that share it for
/// MorphoProtocolAdapter contracts. Beacon management (upgrades, ownership
/// transfer) is performed externally by the beacon owner; this contract
/// retains no authority over the beacon after construction. Used for Morpho
/// Blue protocol integration.
contract MorphoProtocolAdapterBeaconSetDeployer {
    /// Emitted when a new MorphoProtocolAdapter is deployed.
    event Deployment(address sender, address morphoProtocolAdapter);

    /// The beacon for the MorphoProtocolAdapter implementation contracts.
    IBeacon public immutable I_MORPHO_PROTOCOL_ADAPTER_BEACON;

    constructor(MorphoProtocolAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialMorphoProtocolAdapterImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_MORPHO_PROTOCOL_ADAPTER_BEACON =
            new UpgradeableBeacon(config.initialMorphoProtocolAdapterImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new MorphoProtocolAdapter proxy.
    /// @param registry The oracle registry address.
    /// @param vault The vault address this adapter serves.
    /// @param admin Sole governance principal of the deployed adapter:
    /// can call `setRegistry(newRegistry)` to swap the registry pointer
    /// and `setAdmin(newAdmin)` to rotate this role. Distinct from the
    /// `OracleRegistry` admin, which is not affected by this argument.
    /// One-step transfer model — pass an address that cannot be
    /// misaddressed (typically a multisig).
    /// @return adapter The deployed MorphoProtocolAdapter proxy.
    // slither-disable-next-line reentrancy-events
    function newMorphoProtocolAdapter(OracleRegistry registry, address vault, address admin)
        external
        returns (MorphoProtocolAdapter)
    {
        MorphoProtocolAdapter adapter =
            MorphoProtocolAdapter(address(new BeaconProxy(address(I_MORPHO_PROTOCOL_ADAPTER_BEACON), "")));

        if (
            adapter.initialize(
                    abi.encode(MorphoProtocolAdapterConfig({registry: registry, vault: vault, admin: admin}))
                ) != ICLONEABLE_V2_SUCCESS
        ) {
            revert InitializeAdapterFailed();
        }

        emit Deployment(msg.sender, address(adapter));

        return adapter;
    }
}
