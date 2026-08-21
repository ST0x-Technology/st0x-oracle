// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {
    ST0xPriceOracleBeaconSetDeployer,
    ST0xPriceOracleBeaconSetDeployerConfig,
    ZeroImplementation,
    ZeroBeaconOwner
} from "../../../../src/concrete/deploy/ST0xPriceOracleBeaconSetDeployer.sol";
import {ST0xPriceOracleV2} from "../../../mocks/ST0xPriceOracleV2.sol";

contract ST0xPriceOracleBeaconSetDeployerTest is Test {
    ST0xPriceOracle internal implementation;

    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xC0DE);
    address internal constant ORACLE_ADMIN = address(0xADDD);
    uint256 internal constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address internal SIGNER;
    /// @dev A second distinct signer — the differing-config axis for the
    /// CREATE2 divergence tests below (initialize only requires non-zero).
    address internal constant SIGNER_B = address(0x51B2);

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        implementation = new ST0xPriceOracle();
        SIGNER = vm.addr(SIGNER_PK);
        vm.warp(1_000_000);
    }

    function _deployBSD() internal returns (ST0xPriceOracleBeaconSetDeployer) {
        return new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialST0xPriceOracleImplementation: address(implementation)
            })
        );
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroImplementation() external {
        vm.expectRevert(ZeroImplementation.selector);
        new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: BEACON_OWNER, initialST0xPriceOracleImplementation: address(0)
            })
        );
    }

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: address(0), initialST0xPriceOracleImplementation: address(implementation)
            })
        );
    }

    /// @notice Both config fields zero: the implementation check runs FIRST, so
    /// the reported error is `ZeroImplementation` and the owner check is never
    /// reached. Matches the sibling DIA beacon-set deployer, so a misconfigured
    /// deploy always names the implementation slot first across the family.
    function testConstructorReportsZeroImplementationBeforeZeroBeaconOwner() external {
        vm.expectRevert(ZeroImplementation.selector);
        new ST0xPriceOracleBeaconSetDeployer(
            ST0xPriceOracleBeaconSetDeployerConfig({
                initialOwner: address(0), initialST0xPriceOracleImplementation: address(0)
            })
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.iST0xPriceOracleBeacon());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));
    }

    // -------- newST0xPriceOracle --------

    /// @notice The proxy is initialized inside its constructor: signer and
    /// both role grants are live immediately after mint.
    function testNewST0xPriceOracleInitializesState() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        ST0xPriceOracle oracle = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER);

        assertEq(oracle.signer(), SIGNER, "signer set");
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), ADMIN), "admin has default admin role");
        assertTrue(oracle.hasRole(oracle.ORACLE_ADMIN_ROLE(), ORACLE_ADMIN), "oracle admin has oracle admin role");
    }

    /// @notice CREATE2 salt = keccak256(args): minting the same args twice
    /// reverts on the address collision rather than silently forking a second
    /// divergent oracle. Differing args land at a different address.
    function testNewST0xPriceOracleIsIdempotentPerConfig() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        ST0xPriceOracle first = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER);

        // Same args → CREATE2 collision → revert (empty returndata).
        vm.expectRevert();
        bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER);

        // The bare vm.expectRevert above is intentional: a raw CREATE2 address
        // collision carries no selector. Prove it WAS the collision (not an
        // unrelated early revert) — the original instance's code and configured
        // signer survive, so no divergent second instance was forked.
        assertGt(address(first).code.length, 0, "first instance survives the collision");
        assertEq(first.signer(), SIGNER, "first instance config intact after the collision");

        // Differing args → different deterministic address.
        ST0xPriceOracle second = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER_B);
        assertTrue(address(first) != address(second), "distinct args give distinct address");
    }

    function testNewST0xPriceOracleEmitsDeployment() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        ST0xPriceOracle oracle = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(bsd) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(oracle), "oracle mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "Deployment event not emitted");
    }

    /// @notice Same permissionless-mint property as the other deployers, with
    /// the sharpest consequence: an arbitrary caller mints an instance where
    /// the attacker holds BOTH admin roles and the publisher key. Deliberate
    /// (see the `Deployment` NatSpec) — the published address list, not
    /// beacon membership or events, authenticates an instance. If minting is
    /// ever gated, flip this test together with that documentation.
    function testRandoMintsArbitraryConfig() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();

        address attacker = address(0xA77A);
        address rando = address(0xBADD);
        vm.expectEmit(true, false, false, false, address(bsd));
        emit Deployment(rando, address(0));
        vm.prank(rando);
        ST0xPriceOracle minted = bsd.newST0xPriceOracle(attacker, attacker, attacker);

        assertTrue(minted.hasRole(minted.DEFAULT_ADMIN_ROLE(), attacker), "attacker holds DEFAULT_ADMIN_ROLE");
        assertTrue(minted.hasRole(minted.ORACLE_ADMIN_ROLE(), attacker), "attacker holds ORACLE_ADMIN_ROLE");
        assertEq(minted.signer(), attacker, "attacker is the publisher key");
    }

    /// @notice A reverting `initialize` (here a zero signer) bubbles straight up
    /// out of the proxy constructor — there is no magic-value check to swallow
    /// it, unlike the DIA stack's beacon-set deployer.
    function testNewST0xPriceOraclePropagatesInitRevertZeroSigner() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();
        vm.expectRevert(ST0xPriceOracle.ZeroSigner.selector);
        bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, address(0));
    }

    /// @notice `admin` and `oracleAdmin` are equally non-optional. A zero in
    /// EITHER slot bubbles `ZeroAdmin` out of the proxy constructor, so the
    /// deployer can never mint an oracle whose `DEFAULT_ADMIN_ROLE` or
    /// `ORACLE_ADMIN_ROLE` is unassigned — the deployer must not substitute a
    /// default (e.g. the caller) for a missing admin.
    function testNewST0xPriceOraclePropagatesInitRevertZeroAdmin() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();

        vm.expectRevert(ST0xPriceOracle.ZeroAdmin.selector);
        bsd.newST0xPriceOracle(address(0), ORACLE_ADMIN, SIGNER);

        vm.expectRevert(ST0xPriceOracle.ZeroAdmin.selector);
        bsd.newST0xPriceOracle(ADMIN, address(0), SIGNER);

        // Neither reverted mint left an instance behind — a well-formed mint
        // still lands, and it holds the roles the caller actually asked for.
        ST0xPriceOracle oracle = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER);
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), ADMIN), "admin has default admin role");
        assertFalse(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), address(this)), "caller is not a default admin");
    }

    /// @notice The beacon is genuinely SHARED: deploy two singletons with
    /// DISTINCT args, then upgrade the single beacon to a V2 implementation and
    /// prove BOTH proxies retarget (answer the V2-only `implVersion()`), while
    /// each proxy retains its OWN distinct config across the upgrade.
    function testMultipleProxiesShareBeacon() external {
        ST0xPriceOracleBeaconSetDeployer bsd = _deployBSD();

        ST0xPriceOracle a = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER);
        ST0xPriceOracle b = bsd.newST0xPriceOracle(ADMIN, ORACLE_ADMIN, SIGNER_B);
        assertTrue(address(a) != address(b), "proxies must be distinct");

        address beacon = address(bsd.iST0xPriceOracleBeacon());
        assertEq(UpgradeableBeacon(beacon).implementation(), address(implementation));

        // V1 has no `implVersion()` — both proxies revert on it pre-upgrade.
        (bool okA,) = address(a).staticcall(abi.encodeWithSignature("implVersion()"));
        (bool okB,) = address(b).staticcall(abi.encodeWithSignature("implVersion()"));
        assertFalse(okA, "V1 has no implVersion() (a)");
        assertFalse(okB, "V1 has no implVersion() (b)");

        // One beacon upgrade retargets EVERY proxy off that beacon.
        ST0xPriceOracleV2 v2Impl = new ST0xPriceOracleV2();
        vm.prank(BEACON_OWNER);
        UpgradeableBeacon(beacon).upgradeTo(address(v2Impl));

        assertEq(ST0xPriceOracleV2(address(a)).implVersion(), 2, "proxy a retargeted");
        assertEq(ST0xPriceOracleV2(address(b)).implVersion(), 2, "proxy b retargeted");

        // Each proxy retains its OWN distinct config across the upgrade.
        assertEq(a.signer(), SIGNER, "proxy a keeps its own signer");
        assertEq(b.signer(), SIGNER_B, "proxy b keeps its own signer");
    }
}
