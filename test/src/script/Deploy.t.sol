// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";
import {DIAOracleUnifiedDeployer} from "src/concrete/deploy/DIAOracleUnifiedDeployer.sol";
import {DIAVaultOracleBeaconSetDeployer} from "src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {PausableOracleWrapperBeaconSetDeployer} from "src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {DeployExposed} from "test/src/script/DeployExposed.sol";

/// @title DeployTest
/// @notice Unit coverage for the `Deploy` script's `deployDIAStackInfra`
/// helper and the `run()` beacon-owner guard. Exercised as a plain unit test
/// (no broadcast / fork) via a test-only subclass exposing the internal
/// helper.
contract DeployTest is Test {
    DeployExposed internal deploy;

    address internal constant BEACON_OWNER = address(0x6074E12);

    function setUp() public {
        deploy = new DeployExposed();
    }

    /// @notice The helper deploys both beacon-set deployers, owns BOTH beacons
    /// with the requested owner (never the deploy key), and composes them into
    /// a unified deployer whose two immutables point at exactly those BSDs.
    function testDeployDIAStackInfraWiresBeaconsAndOwners() external {
        DIAOracleUnifiedDeployer unified = deploy.exposedDeployDIAStackInfra(BEACON_OWNER);

        DIAVaultOracleBeaconSetDeployer oracleBSD = unified.I_DIA_VAULT_ORACLE_BEACON_SET_DEPLOYER();
        PausableOracleWrapperBeaconSetDeployer wrapperBSD = unified.I_PAUSABLE_ORACLE_WRAPPER_BEACON_SET_DEPLOYER();

        assertTrue(address(oracleBSD) != address(0), "oracle BSD wired");
        assertTrue(address(wrapperBSD) != address(0), "wrapper BSD wired");

        // Both beacons owned by the requested owner — this is the security
        // postcondition `run()` require()s.
        assertEq(
            Ownable(address(oracleBSD.I_DIA_VAULT_ORACLE_BEACON())).owner(),
            BEACON_OWNER,
            "oracle beacon owned by requested owner"
        );
        assertEq(
            Ownable(address(wrapperBSD.I_PAUSABLE_ORACLE_WRAPPER_BEACON())).owner(),
            BEACON_OWNER,
            "wrapper beacon owned by requested owner"
        );
    }

    /// @notice `run()` REQUIRES `BEACON_INITIAL_OWNER != deploy key`: the beacon
    /// owner can swap the implementation behind every proxy, so it must never
    /// be the hot deploy key. Set the env so the two collide and assert the
    /// guard reverts.
    function testRunRevertsWhenBeaconOwnerEqualsDeployKey() external {
        uint256 deployKey = uint256(keccak256("deploy.t.sol.key"));
        address deployer = vm.addr(deployKey);
        vm.setEnv("DEPLOYMENT_KEY", vm.toString(deployKey));
        vm.setEnv("BEACON_INITIAL_OWNER", vm.toString(deployer));
        vm.setEnv("DEPLOYMENT_SUITE", "dia-oracle-unified-deployer");

        vm.expectRevert("BEACON_INITIAL_OWNER must not be the deploy key");
        deploy.run();
    }
}
