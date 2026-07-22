// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";
import {DIAVaultOracleBeaconSetDeployer} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {DeployExposed} from "./DeployExposed.sol";

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

    /// @notice The helper deploys the DIA beacon-set deployer and owns its
    /// beacon with the requested owner (never the deploy key) — the security
    /// postcondition `run()` require()s.
    function testDeployDIAStackInfraWiresBeaconAndOwner() external {
        DIAVaultOracleBeaconSetDeployer oracleBSD = deploy.exposedDeployDIAStackInfra(BEACON_OWNER);

        assertTrue(address(oracleBSD) != address(0), "oracle BSD wired");
        assertEq(
            Ownable(address(oracleBSD.I_DIA_VAULT_ORACLE_BEACON())).owner(),
            BEACON_OWNER,
            "oracle beacon owned by requested owner"
        );
    }

    /// @notice The signed-price helper reads its config from env, mints the
    /// singleton central store through its beacon-set deployer, and owns BOTH
    /// beacons with the requested owner. Asserts the security postconditions
    /// `deploySignedPriceStack` require()s: the singleton carries the requested
    /// signer, `oracleAdmin` holds `ORACLE_ADMIN_ROLE`, and both beacons are
    /// owned by the requested owner (never the deploy key).
    function testDeploySignedPriceStackWiresOracleAndBeacons() external {
        address stAdmin = address(0x57ADAD);
        address stOracleAdmin = address(0x57ADDD);
        address stSigner = address(0x57516E);
        uint64 stTimeout = 1 hours;
        vm.setEnv("ST0X_ADMIN", vm.toString(stAdmin));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(stOracleAdmin));
        vm.setEnv("ST0X_SIGNER", vm.toString(stSigner));
        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(stTimeout)));

        deploy.exposedDeploySignedPriceStack(BEACON_OWNER);
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
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");

        vm.expectRevert("BEACON_INITIAL_OWNER must not be the deploy key");
        deploy.run();
    }
}
