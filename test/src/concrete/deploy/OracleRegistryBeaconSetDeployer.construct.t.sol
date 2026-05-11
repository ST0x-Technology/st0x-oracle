// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {OracleRegistry} from "st0x.oracle/concrete/registry/OracleRegistry.sol";
import {
    OracleRegistryBeaconSetDeployer,
    OracleRegistryBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner,
    InitializeRegistryFailed
} from "st0x.oracle/concrete/deploy/OracleRegistryBeaconSetDeployer.sol";

/// @dev Malicious implementation whose `initialize` returns a non-success
/// sentinel, exercising the `InitializeRegistryFailed` branch in
/// `newOracleRegistry`.
contract BadRegistryImpl {
    function initialize(bytes calldata) external pure returns (bytes32) {
        return bytes32(uint256(0xdead));
    }
}

contract OracleRegistryBeaconSetDeployerConstructTest is Test {
    /// Test that zero implementation address reverts.
    function testConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(ZeroImplementation.selector);
        new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialOracleRegistryImplementation: address(0)
            })
        );
    }

    /// Test that zero beacon owner address reverts.
    function testConstructZeroBeaconOwner(address implementation) external {
        vm.assume(implementation != address(0));
        vm.expectRevert(ZeroBeaconOwner.selector);
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

    /// `newOracleRegistry` must revert `InitializeRegistryFailed` when the
    /// cloned proxy's `initialize` returns the wrong sentinel. Mirrors the
    /// sibling Morpho/MultiPyth pattern; closes audit #56.
    function testNewOracleRegistryRevertsInitFailure() external {
        BadRegistryImpl bad = new BadRegistryImpl();
        OracleRegistryBeaconSetDeployer deployer = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this), initialOracleRegistryImplementation: address(bad)
            })
        );
        vm.expectRevert(InitializeRegistryFailed.selector);
        deployer.newOracleRegistry();
    }

    /// `Deployment` must carry both `caller` and `oracleRegistry` as indexed
    /// topics so indexers can filter by either field. Closes audit #40 / #173.
    function testDeploymentEventIsIndexed(address caller) external {
        vm.assume(caller != address(0));

        OracleRegistry implementation = new OracleRegistry();
        OracleRegistryBeaconSetDeployer deployer = new OracleRegistryBeaconSetDeployer(
            OracleRegistryBeaconSetDeployerConfig({
                initialOwner: address(this), initialOracleRegistryImplementation: address(implementation)
            })
        );

        vm.recordLogs();
        vm.prank(caller);
        OracleRegistry registry = deployer.newOracleRegistry();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployment(address,address)")) {
                assertEq(logs[i].topics.length, 3, "expected 3 topics (signature + 2 indexed)");
                assertEq(logs[i].data.length, 0, "expected empty data (all args indexed)");
                address evCaller = address(uint160(uint256(logs[i].topics[1])));
                address evRegistry = address(uint160(uint256(logs[i].topics[2])));
                assertEq(evCaller, caller);
                assertEq(evRegistry, address(registry));
                found = true;
            }
        }
        assertTrue(found, "Deployment event missing");
    }
}
