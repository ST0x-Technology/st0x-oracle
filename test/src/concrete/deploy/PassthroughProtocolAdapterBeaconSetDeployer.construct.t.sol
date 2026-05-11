// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std-1.16.1/src/Test.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer,
    PassthroughProtocolAdapterBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

contract PassthroughProtocolAdapterBeaconSetDeployerConstructTest is Test {
    function testPassthroughProtocolAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialPassthroughProtocolAdapterImplementation: address(0)
            })
        );
    }

    function testPassthroughProtocolAdapterBeaconSetDeployerConstructZeroBeaconOwner(address initialPassthroughProtocolAdapterImplementation)
        external
    {
        vm.assume(initialPassthroughProtocolAdapterImplementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroBeaconOwner.selector));
        new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(0),
                initialPassthroughProtocolAdapterImplementation: initialPassthroughProtocolAdapterImplementation
            })
        );
    }

    function testPassthroughProtocolAdapterBeaconSetDeployerConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        PassthroughProtocolAdapter implementation = new PassthroughProtocolAdapter();

        PassthroughProtocolAdapterBeaconSetDeployer deployer = new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialPassthroughProtocolAdapterImplementation: address(implementation)
            })
        );

        assertEq(address(deployer.I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON().implementation()), address(implementation));
    }

    /// `Deployment` must carry both `caller` and `passthroughProtocolAdapter`
    /// as indexed topics so indexers can filter by either field. Closes audit
    /// #40 / #173.
    function testDeploymentEventIsIndexed(address vault, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        PassthroughProtocolAdapter implementation = new PassthroughProtocolAdapter();
        PassthroughProtocolAdapterBeaconSetDeployer deployer = new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPassthroughProtocolAdapterImplementation: address(implementation)
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
        PassthroughProtocolAdapter adapter = deployer.newPassthroughProtocolAdapter(registry, vault, admin);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployment(address,address)")) {
                assertEq(logs[i].topics.length, 3, "expected 3 topics (signature + 2 indexed)");
                assertEq(logs[i].data.length, 0, "expected empty data (all args indexed)");
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
