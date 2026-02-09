// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {
    PassthroughProtocolAdapterBeaconSetDeployer,
    PassthroughProtocolAdapterBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/PassthroughProtocolAdapterBeaconSetDeployer.sol";
import {PassthroughProtocolAdapter} from "src/concrete/protocol/PassthroughProtocolAdapter.sol";

contract PassthroughProtocolAdapterBeaconSetDeployerConstructTest is Test {
    function testPassthroughProtocolAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner)
        external
    {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new PassthroughProtocolAdapterBeaconSetDeployer(
            PassthroughProtocolAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner,
                initialPassthroughProtocolAdapterImplementation: address(0)
            })
        );
    }

    function testPassthroughProtocolAdapterBeaconSetDeployerConstructZeroBeaconOwner(
        address initialPassthroughProtocolAdapterImplementation
    ) external {
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
                initialOwner: initialOwner,
                initialPassthroughProtocolAdapterImplementation: address(implementation)
            })
        );

        assertEq(address(deployer.I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON().implementation()), address(implementation));
    }
}
