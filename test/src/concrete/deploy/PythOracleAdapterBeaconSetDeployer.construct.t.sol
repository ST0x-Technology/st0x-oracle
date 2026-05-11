// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "src/concrete/oracle/PythOracleAdapter.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";

contract PythOracleAdapterBeaconSetDeployerConstructTest is Test {
    function testPythOracleAdapterBeaconSetDeployerConstructZeroImplementation(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroImplementation.selector));
        new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialPythOracleAdapterImplementation: address(0)
            })
        );
    }

    function testPythOracleAdapterBeaconSetDeployerConstructZeroBeaconOwner(address initialPythOracleAdapterImplementation)
        external
    {
        vm.assume(initialPythOracleAdapterImplementation != address(0));
        vm.expectRevert(abi.encodeWithSelector(ZeroBeaconOwner.selector));
        new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(0), initialPythOracleAdapterImplementation: initialPythOracleAdapterImplementation
            })
        );
    }

    function testPythOracleAdapterBeaconSetDeployerConstructSuccess(address initialOwner) external {
        vm.assume(initialOwner != address(0));
        PythOracleAdapter implementation = new PythOracleAdapter();

        PythOracleAdapterBeaconSetDeployer deployer = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: initialOwner, initialPythOracleAdapterImplementation: address(implementation)
            })
        );

        assertEq(address(deployer.I_PYTH_ORACLE_ADAPTER_BEACON().implementation()), address(implementation));
    }

    /// `Deployment` must carry both `caller` and `pythOracleAdapter` as
    /// indexed topics so indexers can filter by either field. Decoding from
    /// `topics[1..2]` (not from `data`) is the assertion that locks the
    /// indexed-ness in. Closes audit #40 / #173.
    function testDeploymentEventIsIndexed(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter implementation = new PythOracleAdapter();
        PythOracleAdapterBeaconSetDeployer deployer = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPythOracleAdapterImplementation: address(implementation)
            })
        );

        vm.recordLogs();
        PythOracleAdapter adapter = deployer.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: vault,
                priceId: priceId,
                maxAge: maxAge,
                admin: admin,
                pauseConfig: CorporateActionPauseConfig({
                    corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
                })
            })
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployment(address,address)")) {
                // 3 topics = signature + 2 indexed args. data must be empty.
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
