// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Script, console2} from "forge-std-1.16.1/src/Script.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";

import {DIAVaultOracle} from "../src/concrete/oracle/DIAVaultOracle.sol";
import {PausableOracleWrapper} from "../src/concrete/wrapper/PausableOracleWrapper.sol";
import {ST0xPriceOracle} from "../src/concrete/oracle/ST0xPriceOracle.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {
    PausableOracleWrapperBeaconSetDeployer,
    PausableOracleWrapperBeaconSetDeployerConfig
} from "../src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {
    DIAOracleUnifiedDeployer,
    DIAOracleUnifiedDeployerConstructorConfig
} from "../src/concrete/deploy/DIAOracleUnifiedDeployer.sol";
import {
    ST0xPriceOracleBeaconSetDeployer,
    ST0xPriceOracleBeaconSetDeployerConfig
} from "../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {
    MorphoPairOracleBeaconSetDeployer,
    MorphoPairOracleBeaconSetDeployerConfig
} from "../src/concrete/deploy/MorphoPairOracleBeaconSetDeployer.sol";

/// @dev Deploys the DIA stack infra: fresh implementations, both beacon-set
/// deployers, and the unified deployer composing them. No per-vault proxies
/// are minted — those are deployed per vault through the unified deployer with
/// the correct corporate-action pause config for that vault.
bytes32 constant DEPLOYMENT_SUITE_DIA_ORACLE_UNIFIED_DEPLOYER = keccak256("dia-oracle-unified-deployer");

/// @dev Deploys the signed-price stack infra: a fresh `ST0xPriceOracle`
/// implementation and its beacon-set deployer, the singleton central store
/// minted through that deployer, and a `MorphoPairOracleBeaconSetDeployer`
/// bound to that singleton. No per-market adapter proxies are minted — those
/// are deployed per Morpho market through the adapter beacon-set deployer with
/// the correct base/quote for that market.
bytes32 constant DEPLOYMENT_SUITE_SIGNED_PRICE_STACK = keccak256("signed-price-stack");

/// @title Deploy
/// @notice Deployment entry point consumed by `rainix-sol-artifacts`
/// (`manual-sol-artifacts.yaml`). Dispatches on the DEPLOYMENT_SUITE
/// environment variable; the broadcast key comes from DEPLOYMENT_KEY and the
/// beacon owner from BEACON_INITIAL_OWNER (both required, no defaults).
///
/// Run a suite manually with:
///     DEPLOYMENT_SUITE=dia-oracle-unified-deployer \
///     BEACON_INITIAL_OWNER=0x<governance-multisig> \
///         forge script script/Deploy.sol:Deploy \
///         --rpc-url $ETH_RPC_URL --broadcast \
///         --private-key $DEPLOYMENT_KEY
///
/// Omit `--broadcast` to dry-run.
contract Deploy is Script {
    /// @notice Deploys the DIA stack infra: fresh `DIAVaultOracle` and
    /// `PausableOracleWrapper` implementations, a beacon-set deployer for
    /// each (owning its own beacon), and the `DIAOracleUnifiedDeployer`
    /// composing both. Assumes the caller has an active broadcast.
    /// @param beaconInitialOwner Initial owner of both beacons.
    /// @return unifiedDeployer The deployed `DIAOracleUnifiedDeployer`.
    function deployDIAStackInfra(address beaconInitialOwner) internal returns (DIAOracleUnifiedDeployer) {
        DIAVaultOracle oracleImpl = new DIAVaultOracle();
        PausableOracleWrapper wrapperImpl = new PausableOracleWrapper();

        DIAVaultOracleBeaconSetDeployer oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: beaconInitialOwner, initialDIAVaultOracleImplementation: address(oracleImpl)
            })
        );
        PausableOracleWrapperBeaconSetDeployer wrapperBSD = new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: beaconInitialOwner, initialPausableOracleWrapperImplementation: address(wrapperImpl)
            })
        );

        // Postcondition: both beacons — which control the implementation
        // behind every proxy, i.e. every served price — must be owned by the
        // requested owner, never left with the (hot, CI-held) deploy key.
        require(
            Ownable(address(oracleBSD.I_DIA_VAULT_ORACLE_BEACON())).owner() == beaconInitialOwner,
            "oracle beacon owner mismatch"
        );
        require(
            Ownable(address(wrapperBSD.I_PAUSABLE_ORACLE_WRAPPER_BEACON())).owner() == beaconInitialOwner,
            "wrapper beacon owner mismatch"
        );

        DIAOracleUnifiedDeployer unifiedDeployer = new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );

        console2.log("=== Deployed DIA stack infra ===");
        console2.log("oracleImpl", address(oracleImpl));
        console2.log("wrapperImpl", address(wrapperImpl));
        console2.log("oracleBSD", address(oracleBSD));
        console2.log("wrapperBSD", address(wrapperBSD));
        console2.log("unifiedDeployer", address(unifiedDeployer));

        return unifiedDeployer;
    }

    /// @notice Deploys the signed-price stack infra: a fresh `ST0xPriceOracle`
    /// implementation and its beacon-set deployer, the singleton central store
    /// minted through that deployer, and a `MorphoPairOracleBeaconSetDeployer`
    /// bound to that singleton. No per-market adapter proxies are minted here.
    /// Assumes the caller has an active broadcast. Reads the oracle config from
    /// env: `ST0X_ADMIN`, `ST0X_ORACLE_ADMIN`, `ST0X_SIGNER` (addresses) and
    /// `ST0X_TIMEOUT` (uint64).
    /// @param beaconInitialOwner Initial owner of both beacons.
    function deploySignedPriceStack(address beaconInitialOwner) internal {
        address admin = vm.envAddress("ST0X_ADMIN");
        address oracleAdmin = vm.envAddress("ST0X_ORACLE_ADMIN");
        address signer = vm.envAddress("ST0X_SIGNER");
        uint64 timeout = uint64(vm.envUint("ST0X_TIMEOUT"));

        ST0xPriceOracle oracleImpl = new ST0xPriceOracle();
        ST0xPriceOracleBeaconSetDeployer oracleBSD = new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: beaconInitialOwner, initialST0xPriceOracleImplementation: address(oracleImpl)
            })
        );

        // The singleton central store, minted through its own beacon-set
        // deployer so its creation is atomic and recorded (Deployment event).
        ST0xPriceOracle central = oracleBSD.newST0xPriceOracle(admin, oracleAdmin, signer, timeout);

        MorphoPairOracleBeaconSetDeployer adapterBSD = new MorphoPairOracleBeaconSetDeployer(
            MorphoPairOracleBeaconSetDeployerConfig({initialOwner: beaconInitialOwner, central: central})
        );

        // Postcondition: the central store carries the requested signer and the
        // ORACLE_ADMIN_ROLE grant, so signer/timeout rotation is callable from
        // day one and no post-deploy grant step is left dangling.
        require(central.signer() == signer, "signer mismatch");
        require(central.hasRole(central.ORACLE_ADMIN_ROLE(), oracleAdmin), "oracle admin role not granted");

        // Postcondition: both beacons — which control the implementation behind
        // every proxy, i.e. every served price — must be owned by the requested
        // owner, never left with the (hot, CI-held) deploy key.
        require(
            Ownable(address(oracleBSD.I_ST0X_PRICE_ORACLE_BEACON())).owner() == beaconInitialOwner,
            "oracle beacon owner mismatch"
        );
        require(
            Ownable(address(adapterBSD.I_MORPHO_PAIR_ORACLE_BEACON())).owner() == beaconInitialOwner,
            "adapter beacon owner mismatch"
        );

        console2.log("=== Deployed signed-price stack infra ===");
        console2.log("oracleImpl", address(oracleImpl));
        console2.log("oracleBSD", address(oracleBSD));
        console2.log("central", address(central));
        console2.log("adapterBSD", address(adapterBSD));
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

        if (suite == DEPLOYMENT_SUITE_DIA_ORACLE_UNIFIED_DEPLOYER) {
            vm.startBroadcast(deploymentKey);
            deployDIAStackInfra(beaconInitialOwner);
            vm.stopBroadcast();
        } else if (suite == DEPLOYMENT_SUITE_SIGNED_PRICE_STACK) {
            vm.startBroadcast(deploymentKey);
            deploySignedPriceStack(beaconInitialOwner);
            vm.stopBroadcast();
        } else {
            revert("Unknown deployment suite");
        }
    }
}
