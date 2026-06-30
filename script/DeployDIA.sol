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

/// @title DeployDIA
/// @notice One-shot test deploy of the DIA oracle stack against wtCOIN on
/// Base. Stands up two beacons + the unified deployer, then mints a paired
/// (DIAVaultOracle, PausableOracleWrapper) for wtCOIN priced off DIA's
/// COIN feed.
///
/// Run with:
///     forge script script/DeployDIA.sol:DeployDIA \
///         --rpc-url $ETH_RPC_URL --broadcast \
///         --private-key $DEPLOYMENT_KEY
///
/// Omit `--broadcast` to dry-run.
contract DeployDIA is Script {
    /// DIA Data Association V2 oracle on Base — hosts COIN, AMZN, NVDA,
    /// MSTR, TSLA, IAU, SPYM, SIVR, PPLT, CRCL, BMNR under their bare
    /// symbol keys.
    address constant DIA_ORACLE = 0xCE521b52513242c5094bc56f57887BB2A05B8129;

    /// wtCOIN ERC-4626 vault on Base — the priced share token.
    address constant WTCOIN = 0x5cDa0E1CA4ce2af96315f7F8963C85399c172204;

    /// DIA feed key for Coinbase stock.
    string constant SYMBOL = "COIN";

    /// Max DIA push age in seconds. 2h chosen as DIA promises a 1h
    /// heartbeat (under either 0.1% deviation or 1h elapsed, whichever
    /// fires first) — 2h tolerates one missed heartbeat without us serving
    /// a price that's meaningfully stale during active trading.
    uint256 constant MAX_AGE = 2 hours;

    /// `corporateActionsVault = 0` disables the auto-pause for this test
    /// deploy. tCOIN doesn't have the corporate-actions facet wired yet —
    /// pointing at it would brick every oracle read (ABI-decode of empty
    /// `earliestActionOfType` return reverts in `LibCorporateActionsPause`).
    /// Redeploy a fresh wrapper proxy once the facet lands on tCOIN.
    address constant CORPORATE_ACTIONS_VAULT = address(0);

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYMENT_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== DIA stack test deploy ===");
        console2.log("deployer", deployer);
        console2.log("dia oracle", DIA_ORACLE);
        console2.log("symbol", SYMBOL);
        console2.log("wtCOIN", WTCOIN);
        console2.log("maxAge (sec)", MAX_AGE);
        console2.log("auto-pause disabled (corporateActionsVault = 0)");

        vm.startBroadcast(deployerKey);

        // 1. Implementations (used as the initial beacon implementation).
        DIAVaultOracle oracleImpl = new DIAVaultOracle();
        PausableOracleWrapper wrapperImpl = new PausableOracleWrapper();

        // 2. Per-implementation beacon-set deployers (own beacon construction).
        DIAVaultOracleBeaconSetDeployer oracleBSD = new DIAVaultOracleBeaconSetDeployer(
            DIAVaultOracleBeaconSetDeployerConfig({
                initialOwner: deployer, initialDIAVaultOracleImplementation: address(oracleImpl)
            })
        );
        PausableOracleWrapperBeaconSetDeployer wrapperBSD = new PausableOracleWrapperBeaconSetDeployer(
            PausableOracleWrapperBeaconSetDeployerConfig({
                initialOwner: deployer, initialPausableOracleWrapperImplementation: address(wrapperImpl)
            })
        );

        // 3. Unified deployer (composes both BSDs, atomic oracle+wrapper mint).
        DIAOracleUnifiedDeployer unifiedDeployer = new DIAOracleUnifiedDeployer(
            DIAOracleUnifiedDeployerConstructorConfig({
                diaVaultOracleBeaconSetDeployer: oracleBSD, pausableOracleWrapperBeaconSetDeployer: wrapperBSD
            })
        );

        // 4. Mint the paired (oracle, wrapper) for wtCOIN.
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

        console2.log("=== Deployed addresses ===");
        console2.log("oracleImpl", address(oracleImpl));
        console2.log("wrapperImpl", address(wrapperImpl));
        console2.log("oracleBSD", address(oracleBSD));
        console2.log("wrapperBSD", address(wrapperBSD));
        console2.log("unifiedDeployer", address(unifiedDeployer));
        console2.log("oracle (wtCOIN proxy)", address(oracle));
        console2.log("wrapper (CONSUMER-FACING)", address(wrapper));
    }
}
