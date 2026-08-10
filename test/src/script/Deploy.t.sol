// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {Ownable} from "@openzeppelin-contracts-5.6.1/access/Ownable.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {DIAVaultOracleBeaconSetDeployer} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";
import {ST0xPriceOracleBeaconSetDeployer} from "../../../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {MorphoPairAdapterBeaconSetDeployer} from "../../../src/concrete/deploy/MorphoPairAdapterBeaconSetDeployer.sol";
import {ST0xPriceOracle} from "../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {DIAVaultOracle, DIAVaultOracleConfig} from "../../../src/concrete/oracle/DIAVaultOracle.sol";
import {IDIAOracleV2} from "../../../src/interface/IDIAOracleV2.sol";
import {MockDIAOracle} from "../../mocks/MockDIAOracle.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockCorporateActions} from "../../mocks/MockCorporateActions.sol";
import {ACTION_TYPE_STOCK_SPLIT_V1} from "st0x-deploy-0.1.1/src/interface/ICorporateActionsV1.sol";
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

    // Signed-price stack env values, held as constants so the test can read
    // them back off the deployed central store rather than trusting the
    // script's internal require()s.
    address internal constant ST0X_ADMIN = address(0x57ADAD);
    address internal constant ST0X_ORACLE_ADMIN = address(0x57ADDD);
    address internal constant ST0X_SIGNER = address(0x57516E);
    uint64 internal constant ST0X_TIMEOUT = uint64(1 hours);

    /// @dev Signature of the beacon-set deployers' `Deployment` event. Used to
    /// discriminate WHICH suite `run()` actually dispatched to: the DIA suite
    /// mints no proxies (zero `Deployment` logs) while the signed-price suite
    /// mints exactly one — the singleton central store.
    bytes32 internal constant DEPLOYMENT_EVENT_SIG = keccak256("Deployment(address,address)");

    MockDIAOracle internal diaOracle;
    MockERC4626 internal vault;
    MockCorporateActions internal actions;

    function setUp() public {
        deploy = new DeployExposed();
        diaOracle = new MockDIAOracle();
        vault = new MockERC4626();
        actions = new MockCorporateActions();
        // The oracle derives its corporate-actions vault from vault.asset().
        vault.setAsset(address(actions));
        vm.warp(1_000_000);
    }

    /// @dev Counts `Deployment(address,address)` logs recorded since the last
    /// `vm.recordLogs()`.
    function _countDeploymentLogs() internal returns (uint256 count) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == DEPLOYMENT_EVENT_SIG) {
                count++;
            }
        }
    }

    function _diaOracleConfig() internal view returns (DIAVaultOracleConfig memory) {
        return DIAVaultOracleConfig({
            diaOracle: IDIAOracleV2(address(diaOracle)),
            symbol: "COIN",
            vault: address(vault),
            maxAge: 1 hours,
            actionTypeMask: ACTION_TYPE_STOCK_SPLIT_V1,
            pauseTimeBefore: 3600,
            pauseTimeAfter: 7200 // > maxAge (strict cross-epoch margin)
        });
    }

    /// @notice The helper deploys the DIA beacon-set deployer, owns its beacon
    /// with the requested owner (never the deploy key) — the security
    /// postcondition `run()` require()s — AND points that beacon at a real,
    /// freshly deployed `DIAVaultOracle` implementation.
    ///
    /// The implementation assertion is not cosmetic: `deployDIAStackInfra`'s
    /// only job besides ownership is wiring `new DIAVaultOracle()` behind the
    /// beacon, and a beacon pointed at the wrong contract yields a BSD that
    /// looks perfectly wired (right owner, non-zero beacon) yet mints oracles
    /// that cannot serve a price. Proven end-to-end by actually minting through
    /// the returned BSD and reading the config back off the proxy.
    function testDeployDIAStackInfraWiresBeaconAndOwner() external {
        DIAVaultOracleBeaconSetDeployer oracleBSD = deploy.exposedDeployDIAStackInfra(BEACON_OWNER);

        assertTrue(address(oracleBSD) != address(0), "oracle BSD wired");
        address beacon = address(oracleBSD.iDIAVaultOracleBeacon());
        assertEq(Ownable(beacon).owner(), BEACON_OWNER, "oracle beacon owned by requested owner");

        // The beacon must front a real DIAVaultOracle implementation, freshly
        // deployed by the helper (so: not the script itself, not a zero/EOA
        // address, and not some unrelated contract).
        address impl = UpgradeableBeacon(beacon).implementation();
        assertTrue(impl != address(0), "beacon implementation set");
        assertTrue(impl != address(deploy), "implementation is not the script contract");
        assertGt(impl.code.length, 0, "implementation is a contract");

        // End-to-end: an oracle minted through the returned BSD initializes and
        // reports EXACTLY the config it was minted with.
        DIAVaultOracle oracle = oracleBSD.newDIAVaultOracle(_diaOracleConfig());
        assertEq(oracle.symbol(), "COIN", "minted oracle symbol");
        assertEq(oracle.vault(), address(vault), "minted oracle vault");
        assertEq(oracle.maxAge(), 1 hours, "minted oracle maxAge");
    }

    /// @notice One sequential test covering everything that reads the PROCESS
    /// env (`ST0X_*`, `DEPLOYMENT_KEY`, `BEACON_INITIAL_OWNER`,
    /// `DEPLOYMENT_SUITE`): the signed-price helper's env-config wiring + its
    /// key-separation guards, AND the `run()` entry point's beacon-owner guard,
    /// both-suite dispatch and unknown-suite fall-through.
    ///
    /// ALL of these live in ONE test function on purpose. `vm.setEnv` is
    /// PROCESS-global and not rolled back per test, so splitting scenarios that
    /// touch the SAME env vars into separate test functions lets forge's
    /// concurrent execution race the shared vars and flake. Kept sequential
    /// here, the env mutations are deterministic. `vm.startBroadcast` inside
    /// `run()` is a no-op under `forge test`, so the deploy logic runs
    /// in-process against the test EVM.
    function testDeployEnvConfigDispatchAndKeySeparation() external {
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(ST0X_ORACLE_ADMIN));
        vm.setEnv("ST0X_SIGNER", vm.toString(ST0X_SIGNER));
        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(ST0X_TIMEOUT)));

        // ----- signed-price helper: env-config wiring (#267) -----
        // Happy path: admin/oracleAdmin both distinct from the deploy key, so
        // the guards pass and the stack deploys. Assert the postconditions
        // EXTERNALLY off the returned contracts — independent of the script's
        // own require()s, so a deleted require or a deployer that wired a
        // DIFFERENT signer than env still fails here.
        (
            ST0xPriceOracle central,
            ST0xPriceOracleBeaconSetDeployer oracleBSD,
            MorphoPairAdapterBeaconSetDeployer adapterBSD
        ) = deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        assertEq(central.signer(), ST0X_SIGNER, "signer wired from env");
        assertEq(central.timeout(), ST0X_TIMEOUT, "timeout wired from env");
        assertTrue(
            central.hasRole(central.ORACLE_ADMIN_ROLE(), ST0X_ORACLE_ADMIN), "oracleAdmin granted ORACLE_ADMIN_ROLE"
        );
        assertEq(Ownable(address(oracleBSD.iST0xPriceOracleBeacon())).owner(), BEACON_OWNER, "st0x price beacon owner");
        assertEq(
            Ownable(address(adapterBSD.iMorphoPairAdapterBeacon())).owner(), BEACON_OWNER, "morpho adapter beacon owner"
        );
        assertEq(address(adapterBSD.iCentral()), address(central), "adapter bound to the minted central");

        // ----- run() suite dispatch + beacon-owner guard (#256) -----
        // Done here (before the ST0X_* guard mutations below) while ST0X_ADMIN /
        // ST0X_ORACLE_ADMIN still hold their non-deployer values, so the
        // signed-price success branch's own key-separation guards pass.
        uint256 deployKey = uint256(keccak256("deploy.t.sol.key"));
        address deployer = vm.addr(deployKey);
        vm.setEnv("DEPLOYMENT_KEY", vm.toString(deployKey));
        assertTrue(deployer != BEACON_OWNER && deployer != ST0X_ADMIN, "distinct keys");

        // Guard: `BEACON_INITIAL_OWNER` must differ from the deploy key — the
        // beacon owner can swap the implementation behind every proxy. Reverts
        // BEFORE the suite dispatch, so it runs regardless of the suite value.
        vm.setEnv("BEACON_INITIAL_OWNER", vm.toString(deployer));
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");
        vm.expectRevert("BEACON_INITIAL_OWNER must not be the deploy key");
        deploy.run();

        // Owner now distinct, so the guard passes and we reach the dispatch.
        vm.setEnv("BEACON_INITIAL_OWNER", vm.toString(BEACON_OWNER));

        // Dispatch: "signed-price-stack" routes to `deploySignedPriceStack` and
        // completes without reverting — the ONLY end-to-end exercise of the
        // `DEPLOYMENT_SUITE_SIGNED_PRICE_STACK` match arm. A typo in the
        // constant preimage or a mis-wired arm surfaces here.
        //
        // "Did not revert" alone does NOT prove the RIGHT arm ran — both
        // helpers succeed under this env. Discriminate on an observable each
        // suite emits differently: the signed-price suite mints the singleton
        // central store through its beacon-set deployer, so EXACTLY ONE
        // `Deployment` log; the DIA suite mints no proxies at all, so ZERO. If
        // the two arms are swapped (or either arm calls the other helper), the
        // counts flip and both assertions below fail.
        vm.setEnv("DEPLOYMENT_SUITE", "signed-price-stack");
        vm.recordLogs();
        deploy.run();
        assertEq(_countDeploymentLogs(), 1, "signed-price suite mints exactly the central store");

        // Dispatch: "dia-vault-oracle" routes to `deployDIAStackInfra`, which
        // deploys infra ONLY — no per-vault proxy is minted, so no `Deployment`.
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");
        vm.recordLogs();
        deploy.run();
        assertEq(_countDeploymentLogs(), 0, "dia suite mints no proxies");

        // Fall-through: an unrecognised suite hits the explicit
        // `revert("Unknown deployment suite")`. Pins the fall-through so a
        // future refactor can't silently let an unknown suite no-op green.
        vm.setEnv("DEPLOYMENT_SUITE", "bogus-suite");
        vm.expectRevert("Unknown deployment suite");
        deploy.run();

        // ----- run() forwards the REAL deploy key to the guards (#267) -----
        // `run()` derives `deployer` from DEPLOYMENT_KEY and hands it to
        // `deploySignedPriceStack`, which is what gives that helper's
        // key-separation guards teeth in production. Prove the wiring by
        // pointing ST0X_ADMIN at run()'s own deploy key: the deploy must fail
        // loudly. If run() passed anything else (a placeholder, address(0)) the
        // guard would silently pass and the feed would ship under the hot CI
        // key.
        //
        // These two reverts land INSIDE `run()`'s `vm.startBroadcast`, so
        // `vm.stopBroadcast()` never executes and the cheatcode-level broadcast
        // (not EVM state) survives the revert — close it by hand or the next
        // `run()` fails with "a broadcast is active already".
        vm.setEnv("ST0X_ADMIN", vm.toString(deployer));
        vm.setEnv("DEPLOYMENT_SUITE", "signed-price-stack");
        vm.expectRevert("ST0X_ADMIN must not be the deploy key");
        deploy.run();
        vm.stopBroadcast();

        // Same for ST0X_ORACLE_ADMIN, which rotates signer/timeout directly.
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(deployer));
        vm.expectRevert("ST0X_ORACLE_ADMIN must not be the deploy key");
        deploy.run();
        vm.stopBroadcast();
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(ST0X_ORACLE_ADMIN));

        // ----- ST0X_TIMEOUT uint64 bound (#267) -----
        // `ST0X_TIMEOUT` is read as a uint256 and narrowed to uint64. Solidity's
        // explicit downcast TRUNCATES silently, so a value of 2**64 + 3600 would
        // become a perfectly plausible 3600-second timeout and the deploy would
        // ship a staleness bound nobody asked for. The script's
        // `<= type(uint64).max` guard must reject it by MESSAGE, not truncate.
        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(type(uint64).max) + 1 + 3600));
        vm.expectRevert("ST0X_TIMEOUT overflows uint64");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        // Boundary, the OTHER edge: exactly `type(uint64).max` IS representable,
        // so the script's own guard must let it through (`<=`, not `<`) and the
        // rejection must come from DOWNSTREAM — `ST0xPriceOracle`'s
        // `MAX_TIMEOUT` (30 days) bound, carrying the offending value. A `<`
        // guard here would swap this for the script's string revert.
        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(type(uint64).max)));
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.TimeoutTooLarge.selector, type(uint64).max));
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        vm.setEnv("ST0X_TIMEOUT", vm.toString(uint256(ST0X_TIMEOUT)));

        // ----- signed-price helper: key-separation guards (#267) -----
        // Guard: ST0X_ADMIN holds DEFAULT_ADMIN_ROLE (can rotate the publisher
        // signer), so it must never be the hot deploy key.
        vm.setEnv("ST0X_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        // Guard: ST0X_ORACLE_ADMIN rotates signer/timeout directly — same rule.
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ORACLE_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);
    }
}
