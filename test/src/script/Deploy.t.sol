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

    /// @dev Signature of the beacon-set deployers' `Deployment` event. Used to
    /// discriminate WHICH suite `run()` actually dispatched to: the DIA suite
    /// mints no proxies (zero `Deployment` logs) while the signed-price suite
    /// mints exactly one — the singleton central store.
    bytes32 internal constant DEPLOYMENT_EVENT_SIG = keccak256("Deployment(address,address)");

    /// @dev Selector a failed `vm.env*` read reverts with. Lets the test tell an
    /// aborted env read apart from one of the script's own `require`s: the
    /// env-var tests below prove the deploy aborted ON THE ENV READ rather than
    /// somewhere deeper, without pinning the cheatcode's exact message text.
    bytes4 internal constant CHEATCODE_ERROR_SELECTOR = bytes4(keccak256("CheatcodeError(string)"));

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

    /// @dev Decodes the message out of a `CheatcodeError(string)` revert
    /// payload, asserting the selector on the way so a plain `require` string
    /// can never be mistaken for an aborted cheatcode.
    function _cheatcodeErrorMessage(bytes memory err) internal pure returns (string memory) {
        assertGe(err.length, 4, "revert payload carries a selector");
        bytes4 selector = bytes4(err[0]) | (bytes4(err[1]) >> 8) | (bytes4(err[2]) >> 16) | (bytes4(err[3]) >> 24);
        assertTrue(selector == CHEATCODE_ERROR_SELECTOR, "revert is a cheatcode error, not a require");

        bytes memory payload = new bytes(err.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = err[i + 4];
        }
        return abi.decode(payload, (string));
    }

    /// @dev True when `needle` occurs anywhere in `haystack`.
    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory hay = bytes(haystack);
        bytes memory pin = bytes(needle);
        if (pin.length > hay.length) {
            return false;
        }
        for (uint256 i = 0; i <= hay.length - pin.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < pin.length; j++) {
                if (hay[i + j] != pin[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return true;
            }
        }
        return false;
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
        assertTrue(
            central.hasRole(central.ORACLE_ADMIN_ROLE(), ST0X_ORACLE_ADMIN), "oracleAdmin granted ORACLE_ADMIN_ROLE"
        );

        // The two admin env vars land on DIFFERENT roles, and each lands on the
        // role it was named for. ST0X_ADMIN holds DEFAULT_ADMIN_ROLE — the
        // role-admin that can grant ORACLE_ADMIN_ROLE, i.e. the only way back
        // in if the oracle admin is lost, and so the way to rotate the
        // publisher signer — while ST0X_ORACLE_ADMIN holds the operational
        // ORACLE_ADMIN_ROLE only. Assert the negatives too: asserting the
        // grants are DISJOINT is what catches one env var being dropped and the
        // other passed twice. That collapses the separation the deploy exists
        // to establish into a single key while leaving every positive
        // role-presence assertion above green.
        assertTrue(central.hasRole(central.DEFAULT_ADMIN_ROLE(), ST0X_ADMIN), "admin granted DEFAULT_ADMIN_ROLE");
        assertFalse(
            central.hasRole(central.DEFAULT_ADMIN_ROLE(), ST0X_ORACLE_ADMIN), "oracleAdmin is not the default admin"
        );
        assertFalse(central.hasRole(central.ORACLE_ADMIN_ROLE(), ST0X_ADMIN), "admin does not hold the oracle role");
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

        // The guard sits BEFORE the suite dispatch, so the owner is what fails
        // — not the suite. With the SAME bad owner and a suite string matching
        // no arm, the beacon-owner message still comes back rather than
        // "Unknown deployment suite". Ordering is the point: a guard pushed
        // down into the known-suite arms would leave every later arm unguarded
        // by default, and the guard would stop being a property of `run()`.
        vm.setEnv("DEPLOYMENT_SUITE", "bogus-suite");
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
        //
        // Each arm must also run its deployment INSIDE
        // `vm.startBroadcast(deploymentKey)` / `vm.stopBroadcast()`, which is
        // what makes DEPLOYMENT_KEY — not the script contract — the on-chain
        // sender of every creation, and therefore what makes the addresses
        // reproducible from that key's nonce. Observable here as the deploy
        // key's nonce: the signed-price arm broadcasts FOUR top-level actions
        // (implementation, beacon-set deployer, the `newST0xPriceOracle` mint,
        // adapter beacon-set deployer). An unbroadcast arm would leave the
        // deploy key untouched and attribute the deployment to the script.
        vm.setEnv("DEPLOYMENT_SUITE", "signed-price-stack");
        uint64 nonceBeforeSignedPrice = vm.getNonce(deployer);
        vm.recordLogs();
        deploy.run();
        assertEq(_countDeploymentLogs(), 1, "signed-price suite mints exactly the central store");
        assertEq(
            vm.getNonce(deployer),
            nonceBeforeSignedPrice + 4,
            "signed-price suite broadcasts every action from the deploy key"
        );

        // Dispatch: "dia-vault-oracle" routes to `deployDIAStackInfra`, which
        // deploys infra ONLY — no per-vault proxy is minted, so no `Deployment`.
        // The DIA arm broadcasts TWO creations from the deploy key — the
        // implementation and its beacon-set deployer — for the same reason.
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");
        uint64 nonceBeforeDIA = vm.getNonce(deployer);
        vm.recordLogs();
        deploy.run();
        assertEq(_countDeploymentLogs(), 0, "dia suite mints no proxies");
        assertEq(vm.getNonce(deployer), nonceBeforeDIA + 2, "dia suite broadcasts both creations from the deploy key");

        // Fall-through: an unrecognised suite hits the explicit
        // `revert("Unknown deployment suite")`. Pins the fall-through so a
        // future refactor can't silently let an unknown suite no-op green.
        vm.setEnv("DEPLOYMENT_SUITE", "bogus-suite");
        vm.expectRevert("Unknown deployment suite");
        deploy.run();

        // ----- run(): the process env vars are required, no defaults -----
        // DEPLOYMENT_KEY and BEACON_INITIAL_OWNER are both read with ABORTING
        // accessors, so a value the parser rejects (an absent var, a
        // fat-fingered one, an empty CI secret) fails the deploy loudly. A
        // defaulting read would instead sail through to a SUCCESSFUL deploy
        // under whatever the default happened to be — beacons owned by nobody
        // who was asked for, broadcast from a key nobody chose. Proven against
        // a valid suite and an otherwise-complete env, so the only thing
        // standing between each call and a completed deploy is that one env
        // read. The abort names the failing cheatcode and var, so it can never
        // be confused with one of the script's own `require`s.
        vm.setEnv("DEPLOYMENT_SUITE", "dia-vault-oracle");
        vm.setEnv("BEACON_INITIAL_OWNER", "");
        try deploy.run() {
            fail("BEACON_INITIAL_OWNER must be required, not defaulted");
        } catch (bytes memory err) {
            assertTrue(
                _contains(_cheatcodeErrorMessage(err), "vm.envAddress: failed parsing $BEACON_INITIAL_OWNER"),
                "abort names the BEACON_INITIAL_OWNER env read"
            );
        }
        vm.setEnv("BEACON_INITIAL_OWNER", vm.toString(BEACON_OWNER));

        vm.setEnv("DEPLOYMENT_KEY", "");
        try deploy.run() {
            fail("DEPLOYMENT_KEY must be required, not defaulted");
        } catch (bytes memory err) {
            assertTrue(
                _contains(_cheatcodeErrorMessage(err), "vm.envUint: failed parsing $DEPLOYMENT_KEY"),
                "abort names the DEPLOYMENT_KEY env read"
            );
        }

        // ----- run(): DEPLOYMENT_KEY is REQUIRED, never defaulted -----
        // The broadcast key has no default. An unset (or unparseable)
        // DEPLOYMENT_KEY must abort the whole deploy on the env read, not fall
        // back to some other key and ship the stack broadcast — and owned — by
        // it. Driven through the signed-price suite, the one that MINTS, so
        // "aborted before doing anything" is provable by the absence of the
        // central store's `Deployment` log and not by a revert alone: a
        // defaulting accessor would sail past the beacon-owner and
        // key-separation guards (none of which the default key trips) and
        // deploy the whole stack.
        vm.setEnv("DEPLOYMENT_SUITE", "signed-price-stack");
        vm.setEnv("DEPLOYMENT_KEY", "");
        vm.recordLogs();
        (bool keyRead, bytes memory keyErr) = address(deploy).call(abi.encodeWithSignature("run()"));
        assertFalse(keyRead, "an unset DEPLOYMENT_KEY aborts the deploy");
        assertEq(bytes4(keyErr), CHEATCODE_ERROR_SELECTOR, "aborts on the env read, not deeper in the deploy");
        assertEq(_countDeploymentLogs(), 0, "nothing is deployed without a broadcast key");
        vm.setEnv("DEPLOYMENT_KEY", vm.toString(deployKey));

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

        // Same for ST0X_ORACLE_ADMIN, which rotates the signer directly.
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(deployer));
        vm.expectRevert("ST0X_ORACLE_ADMIN must not be the deploy key");
        deploy.run();
        vm.stopBroadcast();
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(ST0X_ORACLE_ADMIN));

        // And for ST0X_SIGNER: `updatePrice` is permissionless and authorised
        // solely by this signer, so a signer == deploy key ships the feed under
        // CI's control. The guard must reject it by MESSAGE.
        vm.setEnv("ST0X_SIGNER", vm.toString(deployer));
        vm.expectRevert("ST0X_SIGNER must not be the deploy key");
        deploy.run();
        vm.stopBroadcast();
        vm.setEnv("ST0X_SIGNER", vm.toString(ST0X_SIGNER));

        // ----- signed-price helper: key-separation guards (#267) -----
        // Guard: ST0X_ADMIN holds DEFAULT_ADMIN_ROLE (can rotate the publisher
        // signer), so it must never be the hot deploy key.
        vm.setEnv("ST0X_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);

        // Guard: ST0X_ORACLE_ADMIN rotates the signer directly — same rule.
        vm.setEnv("ST0X_ADMIN", vm.toString(ST0X_ADMIN));
        vm.setEnv("ST0X_ORACLE_ADMIN", vm.toString(DEPLOYER));
        vm.expectRevert("ST0X_ORACLE_ADMIN must not be the deploy key");
        deploy.exposedDeploySignedPriceStack(BEACON_OWNER, DEPLOYER);
    }
}
