// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Script, console2} from "forge-std-1.16.1/src/Script.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";

import {DIAVaultOracle} from "../src/concrete/oracle/DIAVaultOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";

/// @dev Deploys the DIA stack infra: a fresh `DIAVaultOracle` implementation
/// and its beacon-set deployer. No per-vault proxies are minted — each vault's
/// oracle is minted afterwards through the beacon-set deployer with that
/// vault's DIA feed + corporate-action pause config.
bytes32 constant DEPLOYMENT_SUITE_DIA_VAULT_ORACLE = keccak256("dia-vault-oracle");

/// @title Deploy
/// @notice Deployment entry point consumed by `rainix-sol-artifacts`
/// (`manual-sol-artifacts.yaml`). Dispatches on the DEPLOYMENT_SUITE
/// environment variable; the broadcast key comes from DEPLOYMENT_KEY and the
/// beacon owner from BEACON_INITIAL_OWNER (both required, no defaults).
///
/// Run the suite manually with (DEPLOYMENT_KEY must be in the ENVIRONMENT —
/// `run()` reads it via `vm.envUint`, so a bare `--private-key` flag with an
/// unexported shell variable aborts with "environment variable not found"):
///     DEPLOYMENT_SUITE=dia-vault-oracle \
///     BEACON_INITIAL_OWNER=0x<governance-multisig> \
///     DEPLOYMENT_KEY=0x<deploy-key> \
///         forge script script/Deploy.sol:Deploy \
///         --rpc-url $ETH_RPC_URL --broadcast
///
/// Omit `--broadcast` to dry-run.
contract Deploy is Script {
    /// @notice Deploys the DIA stack infra: a fresh `DIAVaultOracle`
    /// implementation and its beacon-set deployer (owning the beacon). Assumes
    /// the caller has an active broadcast.
    /// @param beaconInitialOwner Initial owner of the beacon.
    /// @return oracleBSD The deployed `DIAVaultOracleBeaconSetDeployer`.
    function deployDIAStackInfra(address beaconInitialOwner) internal returns (DIAVaultOracleBeaconSetDeployer) {
        DIAVaultOracle oracleImpl = new DIAVaultOracle();

        DIAVaultOracleBeaconSetDeployer oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: beaconInitialOwner, initialDIAVaultOracleImplementation: address(oracleImpl)
            })
        );

        // Postcondition: the beacon — which controls the implementation behind
        // every oracle proxy, i.e. every served price — must be owned by the
        // requested owner, never left with the (hot, CI-held) deploy key.
        require(
            Ownable(address(oracleBSD.iDIAVaultOracleBeacon())).owner() == beaconInitialOwner,
            "oracle beacon owner mismatch"
        );

        console2.log("=== Deployed DIA stack infra ===");
        console2.log("oracleImpl", address(oracleImpl));
        console2.log("oracleBSD", address(oracleBSD));

        return oracleBSD;
    }

    /// @notice Entry point. Dispatches to the requested deployment suite
    /// based on the DEPLOYMENT_SUITE environment variable.
    ///
    /// BEACON_INITIAL_OWNER is REQUIRED and must differ from the deploy key:
    /// the beacon owner can swap the implementation behind every proxy, so it
    /// must be governance (a multisig), never the hot CI deploy key. A missing
    /// var fails the deploy loudly rather than silently owning the beacons
    /// with the deploy key.
    function run() external {
        uint256 deploymentKey = vm.envUint("DEPLOYMENT_KEY");
        address deployer = vm.addr(deploymentKey);
        address beaconInitialOwner = vm.envAddress("BEACON_INITIAL_OWNER");
        require(beaconInitialOwner != deployer, "BEACON_INITIAL_OWNER must not be the deploy key");
        bytes32 suite = keccak256(bytes(vm.envString("DEPLOYMENT_SUITE")));

        console2.log("deployer", deployer);
        console2.log("beacon initial owner", beaconInitialOwner);

        if (suite == DEPLOYMENT_SUITE_DIA_VAULT_ORACLE) {
            vm.startBroadcast(deploymentKey);
            deployDIAStackInfra(beaconInitialOwner);
            vm.stopBroadcast();
        } else {
            revert("Unknown deployment suite");
        }
    }
}
