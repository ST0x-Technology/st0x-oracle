// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";

/// @title DeploymentsRecordTest
/// @notice Guards the committed deployment record (`deployments/<network>.json`)
/// — the canonical, durable record of what is deployed where, recovered from
/// the deploy broadcast so it outlives the CI logs it was parsed from (audit
/// findings #5/#10/#15). This test fails if the DIA-stack record silently rots
/// to zeros or collapses distinct roles onto one address. It does NOT fork —
/// codehash verification against the live chain is a scheduled follow-up once
/// the stack is redeployed onto the current impls (see AGENTS.md §Deployment
/// records).
contract DeploymentsRecordTest is Test {
    function testBaseDIARecordIsComplete() external view {
        string memory json = vm.readFile("deployments/base.json");

        assertEq(vm.parseJsonUint(json, ".chainId"), 8453, "chainId");

        address[5] memory infra = [
            vm.parseJsonAddress(json, ".dia.diaVaultOracleImplementation"),
            vm.parseJsonAddress(json, ".dia.pausableOracleWrapperImplementation"),
            vm.parseJsonAddress(json, ".dia.diaVaultOracleBeaconSetDeployer"),
            vm.parseJsonAddress(json, ".dia.pausableOracleWrapperBeaconSetDeployer"),
            vm.parseJsonAddress(json, ".dia.diaOracleUnifiedDeployer")
        ];
        for (uint256 i = 0; i < infra.length; i++) {
            assertTrue(infra[i] != address(0), "record address must not be zero");
            for (uint256 j = i + 1; j < infra.length; j++) {
                assertTrue(infra[i] != infra[j], "record addresses must be distinct roles");
            }
        }

        // The one live instance pair must be recorded and distinct.
        address oracleProxy = vm.parseJsonAddress(json, ".dia.instances.wtCOIN.oracleProxy");
        address wrapperProxy = vm.parseJsonAddress(json, ".dia.instances.wtCOIN.wrapperProxy");
        assertTrue(oracleProxy != address(0) && wrapperProxy != address(0), "instance proxies recorded");
        assertTrue(oracleProxy != wrapperProxy, "oracle and wrapper proxies distinct");
    }
}
