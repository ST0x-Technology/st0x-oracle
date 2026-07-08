// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/IBeacon.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ICLONEABLE_V2_SUCCESS} from "rain-factory-0.1.1/src/interface/ICloneableV2.sol";
import {PausableOracleWrapper, PausableOracleWrapperConfig} from "src/concrete/wrapper/PausableOracleWrapper.sol";

/// @dev Error raised when a zero address is provided for the implementation.
error ZeroImplementation();

/// @dev Error raised when a zero address is provided for the initial beacon
/// owner. Only constrains construction-time ownership; subsequent owner
/// rotations are the beacon's concern.
error ZeroBeaconOwner();

/// @dev Error raised when initialization of the wrapper returns the wrong
/// magic value. Indicates an implementation regression — should never fire
/// in production.
error InitializeWrapperFailed();

/// @title PausableOracleWrapperBeaconSetDeployerConfig
/// @notice Configuration for the `PausableOracleWrapperBeaconSetDeployer`
/// constructor.
/// @param initialOwner The initial owner of the beacon (controls upgrades).
/// @param initialPausableOracleWrapperImplementation The initial
/// implementation contract behind the beacon.
struct PausableOracleWrapperBeaconSetDeployerConfig {
    address initialOwner;
    address initialPausableOracleWrapperImplementation;
}

/// @title PausableOracleWrapperBeaconSetDeployer
/// @notice Deploys a beacon and the `PausableOracleWrapper` proxies that
/// share it. Beacon management (upgrades, ownership transfer) is performed
/// externally by the beacon owner; this contract retains no authority over
/// the beacon after construction.
contract PausableOracleWrapperBeaconSetDeployer {
    /// @notice Emitted when a new PausableOracleWrapper proxy is deployed.
    /// @param caller The direct on-chain caller of `newPausableOracleWrapper`.
    /// For wrappers created via `ChronicleOracleUnifiedDeployer` this is the
    /// unified deployer contract, not the originating EOA. Indexed.
    /// @param wrapper The address of the new proxy. Indexed for filtering.
    event Deployment(address indexed caller, address indexed wrapper);

    /// The beacon for the PausableOracleWrapper implementation contracts.
    IBeacon public immutable I_PAUSABLE_ORACLE_WRAPPER_BEACON;

    constructor(PausableOracleWrapperBeaconSetDeployerConfig memory config) {
        if (config.initialPausableOracleWrapperImplementation == address(0)) {
            revert ZeroImplementation();
        }
        if (config.initialOwner == address(0)) {
            revert ZeroBeaconOwner();
        }

        I_PAUSABLE_ORACLE_WRAPPER_BEACON =
            new UpgradeableBeacon(config.initialPausableOracleWrapperImplementation, config.initialOwner);
    }

    /// @notice Deploys and initializes a new PausableOracleWrapper proxy.
    /// @param config The initialization configuration.
    /// @return wrapper The deployed proxy as a typed reference.
    // slither-disable-next-line reentrancy-events
    function newPausableOracleWrapper(PausableOracleWrapperConfig memory config)
        external
        returns (PausableOracleWrapper wrapper)
    {
        wrapper = PausableOracleWrapper(address(new BeaconProxy(address(I_PAUSABLE_ORACLE_WRAPPER_BEACON), "")));

        if (wrapper.initialize(abi.encode(config)) != ICLONEABLE_V2_SUCCESS) {
            revert InitializeWrapperFailed();
        }

        emit Deployment(msg.sender, address(wrapper));

        return wrapper;
    }
}
