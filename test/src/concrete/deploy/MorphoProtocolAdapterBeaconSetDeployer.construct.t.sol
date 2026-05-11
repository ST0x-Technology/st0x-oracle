// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {
    MorphoProtocolAdapterBeaconSetDeployer,
    MorphoProtocolAdapterBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner,
    InitializeAdapterFailed
} from "src/concrete/deploy/MorphoProtocolAdapterBeaconSetDeployer.sol";
import {MorphoProtocolAdapter} from "src/concrete/protocol/MorphoProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

/// @dev Malicious adapter implementation whose `initialize` returns a non-
/// success sentinel, exercising the `InitializeAdapterFailed` branch in
/// `newMorphoProtocolAdapter`.
contract BadMorphoImpl {
    // slither-disable-next-line unused-state
    OracleRegistry public registry;
    // slither-disable-next-line unused-state
    address public vault;
    // slither-disable-next-line unused-state
    address public admin;

    function initialize(bytes calldata) external pure returns (bytes32) {
        return bytes32(uint256(0xdead));
    }
}

contract MorphoProtocolAdapterBeaconSetDeployerConstructTest is Test {
    function testMorphoProtocolAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialMorphoProtocolAdapterImplementation: address(0)
            })
        );
    }

    function testMorphoProtocolAdapterBeaconSetDeployerConstructZeroBeaconOwner(address initialMorphoProtocolAdapterImplementation)
        external
    {
        vm.assume(initialMorphoProtocolAdapterImplementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroBeaconOwner.selector));
        new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(0),
                initialMorphoProtocolAdapterImplementation: initialMorphoProtocolAdapterImplementation
            })
        );
    }

    function testMorphoProtocolAdapterBeaconSetDeployerConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        MorphoProtocolAdapter implementation = new MorphoProtocolAdapter();

        MorphoProtocolAdapterBeaconSetDeployer deployer = new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialMorphoProtocolAdapterImplementation: address(implementation)
            })
        );

        assertEq(address(deployer.I_MORPHO_PROTOCOL_ADAPTER_BEACON().implementation()), address(implementation));
    }

    /// `newMorphoProtocolAdapter` must revert with `InitializeAdapterFailed`
    /// when the cloned adapter's `initialize` does not return
    /// `ICLONEABLE_V2_SUCCESS`. Closes audit #53.
    function testNewMorphoProtocolAdapterRevertsInitializeFailure() external {
        BadMorphoImpl badImpl = new BadMorphoImpl();
        MorphoProtocolAdapterBeaconSetDeployer deployer = new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMorphoProtocolAdapterImplementation: address(badImpl)
            })
        );

        vm.expectRevert(abi.encodeWithSelector(InitializeAdapterFailed.selector));
        deployer.newMorphoProtocolAdapter(OracleRegistry(address(0xCAFE)), address(0xBEEF), address(this));
    }

    /// `newMorphoProtocolAdapter` must emit `Deployment(sender, adapter)` on
    /// the success path. The existing construct tests only exercise the
    /// constructor; this exercises the deploy path. Closes audit #53.
    function testNewMorphoProtocolAdapterEmitsDeploymentEvent(address vault, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        MorphoProtocolAdapter implementation = new MorphoProtocolAdapter();
        MorphoProtocolAdapterBeaconSetDeployer deployer = new MorphoProtocolAdapterBeaconSetDeployer(
            MorphoProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMorphoProtocolAdapterImplementation: address(implementation)
            })
        );

        OracleRegistry registryImpl = new OracleRegistry();
        OracleRegistryBeaconSetDeployer registryDeployer = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this), initialOracleRegistryImplementation: address(registryImpl)
            })
        );
        OracleRegistry registry = registryDeployer.newOracleRegistry();

        vm.recordLogs();
        MorphoProtocolAdapter adapter = deployer.newMorphoProtocolAdapter(registry, vault, admin);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployment(address,address)")) {
                // Both fields are indexed — decode from topics, not data.
                address caller = address(uint160(uint256(logs[i].topics[1])));
                address adapterAddr = address(uint160(uint256(logs[i].topics[2])));
                assertEq(caller, address(this));
                assertEq(adapterAddr, address(adapter));
                found = true;
            }
        }
        assertTrue(found, "Deployment event missing");
    }
}
