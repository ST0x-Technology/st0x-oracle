// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";

import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";

import {ST0xPriceOracle} from "src/concrete/oracle/ST0xPriceOracle.sol";
import {MorphoPairOracle} from "src/concrete/oracle/MorphoPairOracle.sol";
import {MorphoPairOracleV2} from "test/mocks/MorphoPairOracleV2.sol";

/// @title MorphoPairOracleTest
/// @notice Unit coverage for the `MorphoPairOracle` beacon-proxied
/// forwarding adapter: verbatim forwarding of the central `price(pairId)`
/// (reverts included), constructor / initializer guards, and the shared
/// beacon upgrade retargeting every deployed adapter proxy at once.
contract MorphoPairOracleTest is Test {
    uint256 constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address SIGNER;

    address constant ADMIN = address(0xC0DE);

    address constant BASE_TOKEN = address(0xAAA1);
    address constant QUOTE_TOKEN = address(0xBBB2);
    uint64 constant TIMEOUT = 1 hours;

    bytes32 PAIR_A;
    bytes32 constant PAIR_UNKNOWN = keccak256("pair-unknown");

    ST0xPriceOracle oracle;
    UpgradeableBeacon adapterBeacon;

    function setUp() public {
        SIGNER = vm.addr(SIGNER_PK);
        // Same shape as production: implementation behind a beacon proxy.
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), ADMIN);
        oracle = ST0xPriceOracle(
            address(
                new BeaconProxy(address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, SIGNER, TIMEOUT)))
            )
        );

        // The adapter beacon, shared by every MorphoPairOracle proxy.
        MorphoPairOracle adapterImpl = new MorphoPairOracle(oracle);
        adapterBeacon = new UpgradeableBeacon(address(adapterImpl), ADMIN);

        PAIR_A = oracle.pairId(BASE_TOKEN, QUOTE_TOKEN);
    }

    /// @notice The adapter is literally the interface: `price()` forwards
    /// `iCentral.price(sPairId)` verbatim, unset/staleness reverts included.
    function test_MorphoPairOracle_ForwardsVerbatim() public {
        MorphoPairOracle adapter = _deployAdapter(PAIR_A);
        assertEq(address(adapter.iCentral()), address(oracle), "central wired");
        assertEq(adapter.sPairId(), PAIR_A, "pairId wired");

        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUnset.selector, PAIR_A));
        adapter.price();

        _push(PAIR_A, 42e18, block.timestamp);
        assertEq(adapter.price(), 42e18, "forwards the central price");

        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceStale.selector, PAIR_A));
        adapter.price();
    }

    function test_MorphoPairOracle_ZeroCentral_Reverts() public {
        vm.expectRevert(MorphoPairOracle.ZeroCentral.selector);
        new MorphoPairOracle(ST0xPriceOracle(address(0)));
    }

    function test_MorphoPairOracle_InitializeOnlyOnce() public {
        MorphoPairOracle adapter = _deployAdapter(PAIR_A);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(PAIR_UNKNOWN);
    }

    function test_MorphoPairOracle_ImplementationInitializersDisabled() public {
        MorphoPairOracle impl = new MorphoPairOracle(oracle);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(PAIR_A);
    }

    /// @notice One shared-beacon upgrade retargets EVERY deployed adapter
    /// proxy at once, with per-proxy state (`sPairId`) and the
    /// implementation immutable (`iCentral`) surviving the upgrade.
    function test_MorphoPairOracle_BeaconUpgradeRetargetsAllProxies() public {
        bytes32 pairB = oracle.pairId(QUOTE_TOKEN, BASE_TOKEN);
        MorphoPairOracle adapterA = _deployAdapter(PAIR_A);
        MorphoPairOracle adapterB = _deployAdapter(pairB);

        // V1 has no `version()` — both proxies revert on it pre-upgrade.
        (bool okBefore,) = address(adapterA).staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "V1 has no version()");

        // One beacon upgrade...
        MorphoPairOracleV2 v2Impl = new MorphoPairOracleV2(oracle);
        vm.prank(ADMIN);
        adapterBeacon.upgradeTo(address(v2Impl));

        // ...retargets ALL deployed adapters.
        assertEq(MorphoPairOracleV2(address(adapterA)).version(), 2, "adapter A retargeted");
        assertEq(MorphoPairOracleV2(address(adapterB)).version(), 2, "adapter B retargeted");

        // Per-proxy state survives the upgrade and forwarding still works.
        assertEq(adapterA.sPairId(), PAIR_A, "adapter A proxy state intact");
        assertEq(adapterB.sPairId(), pairB, "adapter B proxy state intact");
        assertEq(address(adapterA.iCentral()), address(oracle), "central immutable intact");
        _push(PAIR_A, 42e18, block.timestamp);
        assertEq(adapterA.price(), 42e18, "still forwards the central price");
    }

    // -------- Helpers --------

    function _deployAdapter(bytes32 id) internal returns (MorphoPairOracle) {
        return MorphoPairOracle(
            address(new BeaconProxy(address(adapterBeacon), abi.encodeCall(MorphoPairOracle.initialize, (id))))
        );
    }

    function _digest(bytes32 id, uint256 price, uint256 timestamp) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(oracle.PRICE_UPDATE_TYPEHASH(), id, price, timestamp));
        return keccak256(abi.encodePacked("\x19\x01", oracle.domainSeparator(), structHash));
    }

    function _sign(bytes32 id, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, _digest(id, price, timestamp));
        return abi.encodePacked(r, s, v);
    }

    function _push(bytes32 id, uint256 price, uint256 timestamp) internal {
        assertTrue(oracle.updatePrice(id, price, timestamp, _sign(id, price, timestamp)));
    }
}
