// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Script, console2} from "forge-std-1.16.1/src/Script.sol";

import {IDIAOracleV2} from "src/interface/IDIAOracleV2.sol";
import {DIAVaultOracle, DIAVaultOracleConfig} from "src/concrete/oracle/DIAVaultOracle.sol";
import {PausableOracleWrapper, CorporateActionPauseConfig} from "src/concrete/wrapper/PausableOracleWrapper.sol";
import {
    DIAVaultOracleBeaconSetDeployer,
    DIAVaultOracleBeaconSetDeployerConfig
} from "src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {
    PausableOracleWrapperBeaconSetDeployer,
    PausableOracleWrapperBeaconSetDeployerConfig
} from "src/concrete/deploy/PausableOracleWrapperBeaconSetDeployer.sol";
import {
    DIAOracleUnifiedDeployer,
    DIAOracleUnifiedDeployerConstructorConfig,
    DIAOracleUnifiedDeployConfig
} from "src/concrete/deploy/DIAOracleUnifiedDeployer.sol";

/// @dev Deploys the DIA stack infra: fresh implementations, both beacon-set
/// deployers, and the unified deployer composing them. No per-vault proxies
/// are minted.
bytes32 constant DEPLOYMENT_SUITE_DIA_ORACLE_UNIFIED_DEPLOYER = keccak256("dia-oracle-unified-deployer");

/// @dev Deploys the DIA stack infra AND mints a paired
/// (DIAVaultOracle, PausableOracleWrapper) for wtCOIN priced off DIA's COIN
/// feed, with the auto-pause disabled. Intended for test deploys.
bytes32 constant DEPLOYMENT_SUITE_DIA_STACK_TEST_DEPLOY = keccak256("dia-stack-test-deploy");

/// @title Deploy
/// @notice Deployment entry point consumed by `rainix-sol-artifacts`
/// (`manual-sol-artifacts.yaml`). Dispatches on the DEPLOYMENT_SUITE
/// environment variable; the broadcast key comes from DEPLOYMENT_KEY.
///
/// Run a suite manually with:
///     DEPLOYMENT_SUITE=dia-oracle-unified-deployer \
///         forge script script/Deploy.sol:Deploy \
///         --rpc-url $ETH_RPC_URL --broadcast \
///         --private-key $DEPLOYMENT_KEY
///
/// Omit `--broadcast` to dry-run.
contract Deploy is Script {
    /// DIA Data Association V2 oracle on Base — hosts COIN, AMZN, NVDA,
    /// MSTR, TSLA, IAU, SPYM, SIVR, PPLT, CRCL, BMNR under their bare
    /// symbol keys.
    address constant DIA_ORACLE = 0xCE521b52513242c5094bc56f57887BB2A05B8129;

    /// wtCOIN ERC-4626 vault on Base — the priced share token for the test
    /// deploy suite.
    address constant WTCOIN = 0x5cDa0E1CA4ce2af96315f7F8963C85399c172204;

    /// DIA feed key for Coinbase stock.
    string constant SYMBOL = "COIN";

    /// Max DIA push age in seconds. 2h chosen as DIA promises a 1h
    /// heartbeat (under either 0.1% deviation or 1h elapsed, whichever
    /// fires first) — 2h tolerates one missed heartbeat without us serving
    /// a price that's meaningfully stale during active trading.
    uint256 constant MAX_AGE = 2 hours;

    /// `corporateActionsVault = 0` disables the auto-pause for the test
    /// deploy. tCOIN doesn't have the corporate-actions facet wired yet —
    /// pointing at it would brick every oracle read (ABI-decode of empty
    /// `earliestActionOfType` return reverts in `LibCorporateActionsPause`).
    /// Redeploy a fresh wrapper proxy once the facet lands on tCOIN.
    address constant CORPORATE_ACTIONS_VAULT = address(0);

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

    /// @notice Entry point. Dispatches to the requested deployment suite
    /// based on the DEPLOYMENT_SUITE environment variable.
    ///
    /// BEACON_INITIAL_OWNER optionally overrides the initial owner of the
    /// deployed beacons; it defaults to the deployer address.
    function run() external {
        uint256 deploymentKey = vm.envUint("DEPLOYMENT_KEY");
        address deployer = vm.addr(deploymentKey);
        address beaconInitialOwner = vm.envOr("BEACON_INITIAL_OWNER", deployer);
        bytes32 suite = keccak256(bytes(vm.envString("DEPLOYMENT_SUITE")));

        console2.log("deployer", deployer);
        console2.log("beacon initial owner", beaconInitialOwner);

        if (suite == DEPLOYMENT_SUITE_DIA_ORACLE_UNIFIED_DEPLOYER) {
            vm.startBroadcast(deploymentKey);
            deployDIAStackInfra(beaconInitialOwner);
            vm.stopBroadcast();
        } else if (suite == DEPLOYMENT_SUITE_DIA_STACK_TEST_DEPLOY) {
            vm.startBroadcast(deploymentKey);
            DIAOracleUnifiedDeployer unifiedDeployer = deployDIAStackInfra(beaconInitialOwner);

            (DIAVaultOracle oracle, PausableOracleWrapper wrapper) = unifiedDeployer.newOracleWithWrapper(
                DIAOracleUnifiedDeployConfig({
                    admin: deployer,
                    oracleConfig: DIAVaultOracleConfig({
                        diaOracle: IDIAOracleV2(DIA_ORACLE), symbol: SYMBOL, vault: WTCOIN, maxAge: MAX_AGE
                    }),
                    pauseConfig: CorporateActionPauseConfig({
                        corporateActionsVault: CORPORATE_ACTIONS_VAULT,
                        actionTypeMask: 0,
                        pauseTimeBefore: 0,
                        pauseTimeAfter: 0
                    })
                })
            );
            vm.stopBroadcast();

            console2.log("oracle (wtCOIN proxy)", address(oracle));
            console2.log("wrapper (CONSUMER-FACING)", address(wrapper));
        } else {
            revert("Unknown deployment suite");
        }
    }
}
