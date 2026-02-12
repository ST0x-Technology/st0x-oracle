// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain.factory/interface/ICloneableV2.sol";
import {
    PassthroughProtocolAdapter,
    PassthroughProtocolAdapterConfig
} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the protocol adapter fails.
error InitializeAdapterFailed();

/// @title PassthroughProtocolAdapterBeaconSetDeployerConfig
/// @notice Configuration for the PassthroughProtocolAdapterBeaconSetDeployer
/// construction.
/// @param initialOwner The initial owner of the beacon.
/// @param initialPassthroughProtocolAdapterImplementation The initial
/// implementation.
struct PassthroughProtocolAdapterBeaconSetDeployerConfig {
    address initialOwner;
    address initialPassthroughProtocolAdapterImplementation;
}

/// @title PassthroughProtocolAdapterBeaconSetDeployer
/// @notice Deploys and manages a beacon set for PassthroughProtocolAdapter
/// contracts. Used for Aave V3, Compound V3, and any future
/// Chainlink-compatible protocol.
contract PassthroughProtocolAdapterBeaconSetDeployer {
    /// Emitted when a new PassthroughProtocolAdapter is deployed.
    event Deployment(address sender, address passthroughProtocolAdapter);

    /// The beacon for the PassthroughProtocolAdapter implementation contracts.
    IBeacon public immutable I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON;

    constructor(PassthroughProtocolAdapterBeaconSetDeployerConfig memory config) {
        if (config.initialPassthroughProtocolAdapterImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON =
            new UpgradeableBeacon(config.initialPassthroughProtocolAdapterImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new PassthroughProtocolAdapter proxy.
    /// @param registry The oracle registry address.
    /// @param vault The vault address this adapter serves.
    /// @param admin The admin address.
    /// @return adapter The deployed PassthroughProtocolAdapter proxy.
    // slither-disable-next-line reentrancy-events
    function newPassthroughProtocolAdapter(OracleRegistry registry, address vault, address admin)
        external
        returns (PassthroughProtocolAdapter)
    {
        PassthroughProtocolAdapter adapter = PassthroughProtocolAdapter(
            address(new BeaconProxy(address(I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON), ""))
        );

        if (
            adapter.initialize(
                    abi.encode(PassthroughProtocolAdapterConfig({registry: registry, vault: vault, admin: admin}))
                ) != ICLONEABLE_V2_SUCCESS
        ) {
            revert InitializeAdapterFailed();
        }

        emit Deployment(msg.sender, address(adapter));

        return adapter;
    }
}
