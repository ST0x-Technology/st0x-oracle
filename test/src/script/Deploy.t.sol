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
    address internal constant DEPLOYER = address(0xDEB10E);

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
    /// singleton central store through its beacon-set deployer, and enforces the
    /// deploy-key-separation guards. All three scenarios live in ONE test
    /// function on purpose: `deploySignedPriceStack` reads its config from
    /// PROCESS env (`vm.setEnv`), which is global and not rolled back per test,
    /// so splitting the scenarios into separate test functions lets forge's
    /// concurrent test execution race the shared `ST0X_*` vars and flake. Kept
    /// sequential here, the env mutations are deterministic.
    function testDeploySignedPriceStackEnvConfigAndKeySeparation() external {
        vm.setEnv("ST0X_ADMIN", vm.toString(address(0x57ADAD)));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(address(0x57ADDD)));
        vm.setEnv("ST0X_SIGNER", vm.toString(address(0x57516E)));
        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(1 hours)));

        // Happy path: admin/oracleAdmin both distinct from the deploy key, so
        // the guards pass and the stack deploys (internal require()s enforce the
        // signer/role/beacon-owner postconditions).
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        // Guard: ST0X_ADMIN holds DEFAULT_ADMIN_ROLE (can rotate the publisher
        // signer), so it must never be the hot deploy key.
        vm.setEnv("ST0X_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        // Guard: ST0X_ORACLE_ADMIN rotates signer/timeout directly — same rule.
        vm.setEnv("ST0X_ADMIN", vm.toString(address(0x57ADAD)));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ORACLE_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);
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
