// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

contract OracleRegistryBeaconSetDeployerConstructTest is Test {
    /// Test that zero implementation address reverts.
    function testConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialOracleRegistryImplementation: address(0)
            })
        );
    }

    /// Test that zero beacon owner address reverts.
    function testConstructZeroBeaconOwner(address implementation) external {
        vm.assume(implementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroBeaconOwner.selector));
        new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(0), initialOracleRegistryImplementation: implementation
            })
        );
    }

    /// Test successful construction creates beacon.
    function testConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));

        OracleRegistry implementation = new OracleRegistry();

        OracleRegistryBeaconSetDeployer deployer = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialOracleRegistryImplementation: address(implementation)
            })
        );

        assertTrue(address(deployer.I_ORACLE_REGISTRY_BEACON()) != address(0));
    }
}
