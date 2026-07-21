// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {Vm} from "forge-std-1.16.1/src/Vm.sol";
import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {MorphoPairOracle, ZeroToken, IdenticalTokens} from "../../../../src/concrete/oracle/MorphoPairOracle.sol";
import {
    MorphoPairOracleBeaconSetDeployer,
    MorphoPairOracleBeaconSetDeployerConfig,
    ZeroBeaconOwner
} from "../../../../src/concrete/deploy/MorphoPairOracleBeaconSetDeployer.sol";
import {MorphoPairOracleV2} from "../../../mocks/MorphoPairOracleV2.sol";
import {MockERC20Decimals} from "../../../mocks/MockERC20Decimals.sol";

contract MorphoPairOracleBeaconSetDeployerTest is Test {
    uint256 internal constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address internal SIGNER;

    address internal constant BEACON_OWNER = address(0xBEEF);
    address internal constant ADMIN = address(0xC0DE);
    uint64 internal constant TIMEOUT = 1 hours;

    ST0xPriceOracle internal central;
    MockERC20Decimals internal base;
    MockERC20Decimals internal quote;

    event Deployment(address indexed caller, address indexed oracle);

    function setUp() public {
        SIGNER = vm.addr(SIGNER_PK);
        vm.warp(1_000_000);

        // The central store, shaped as in production: impl behind a beacon proxy.
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), ADMIN);
        central = ST0xPriceOracle(
            address(
                new BeaconProxy(
                    address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ADMIN, SIGNER, TIMEOUT))
                )
            )
        );

        // base = Morpho collateral (18 dec), quote = Morpho loan (6 dec).
        base = new MockERC20Decimals(18);
        quote = new MockERC20Decimals(6);
    }

    function _deployBSD() internal returns (MorphoPairOracleBeaconSetDeployer) {
        return new MorphoPairOracleBeaconSetDeployer(
            MorphoPairOracleBeaconSetDeployerConfig({initialOwner: BEACON_OWNER, central: central})
        );
    }

    // -------- Constructor validation --------

    function testConstructorRevertsZeroBeaconOwner() external {
        vm.expectRevert(ZeroBeaconOwner.selector);
        new MorphoPairOracleBeaconSetDeployer(
            MorphoPairOracleBeaconSetDeployerConfig({initialOwner: address(0), central: central})
        );
    }

    /// @notice A zero central is caught by `MorphoPairOracle.ZeroCentral` in the
    /// implementation constructor the deployer builds — no local guard needed.
    function testConstructorRevertsZeroCentral() external {
        vm.expectRevert(MorphoPairOracle.ZeroCentral.selector);
        new MorphoPairOracleBeaconSetDeployer(
            MorphoPairOracleBeaconSetDeployerConfig({initialOwner: BEACON_OWNER, central: ST0xPriceOracle(address(0))})
        );
    }

    function testConstructorHappyPathDeploysBeacon() external {
        MorphoPairOracleBeaconSetDeployer bsd = _deployBSD();
        address beacon = address(bsd.I_MORPHO_PAIR_ORACLE_BEACON());
        assertTrue(beacon != address(0));
        assertEq(UpgradeableBeacon(beacon).owner(), BEACON_OWNER);
        assertEq(address(bsd.I_CENTRAL()), address(central), "central immutable wired");

        // The beacon's implementation is bound to the same central store.
        MorphoPairOracle impl = MorphoPairOracle(UpgradeableBeacon(beacon).implementation());
        assertEq(address(impl.iCentral()), address(central), "impl bound to central");
    }

    // -------- newMorphoPairOracle --------

    /// @notice The proxy is initialized inside its constructor: pairId, base,
    /// quote wired and the publisher-scaled value rescaled to Morpho convention.
    /// base=18dec, quote=6dec, signed=42e18 ⇒ price() = 42 * 10^(36+6-18) = 42e24.
    function testNewMorphoPairOracleWiresAndRescales() external {
        MorphoPairOracleBeaconSetDeployer bsd = _deployBSD();
        MorphoPairOracle adapter = bsd.newMorphoPairOracle(address(base), address(quote));

        bytes32 pair = central.pairId(address(base), address(quote));
        assertEq(adapter.pairId(), pair, "pairId wired");
        assertEq(adapter.baseToken(), address(base), "base wired");
        assertEq(adapter.quoteToken(), address(quote), "quote wired");
        assertEq(address(adapter.iCentral()), address(central), "central wired");

        _push(pair, 42e18, block.timestamp);
        assertEq(adapter.price(), 42e24, "42.0 loan/collateral in Morpho scale");
    }

    /// @notice CREATE2 salt = keccak256(base, quote): minting the same pair twice
    /// reverts on the address collision rather than silently forking a second
    /// divergent adapter. A differing pair lands at a different address.
    function testNewMorphoPairOracleIsIdempotentPerConfig() external {
        MorphoPairOracleBeaconSetDeployer bsd = _deployBSD();
        MorphoPairOracle first = bsd.newMorphoPairOracle(address(base), address(quote));

        // Same pair → CREATE2 collision → revert (empty returndata).
        vm.expectRevert();
        bsd.newMorphoPairOracle(address(base), address(quote));

        // Differing pair → different deterministic address.
        MockERC20Decimals quote2 = new MockERC20Decimals(8);
        MorphoPairOracle second = bsd.newMorphoPairOracle(address(base), address(quote2));
        assertTrue(address(first) != address(second), "distinct pair gives distinct address");
    }

    function testNewMorphoPairOracleEmitsDeployment() external {
        MorphoPairOracleBeaconSetDeployer bsd = _deployBSD();

        vm.recordLogs();
        MorphoPairOracle adapter = bsd.newMorphoPairOracle(address(base), address(quote));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 sig = keccak256("Deployment(address,address)");
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].emitter == address(bsd) && entries[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(entries[i].topics[1]))), address(this), "caller mismatch");
                assertEq(address(uint160(uint256(entries[i].topics[2]))), address(adapter), "oracle mismatch");
                found = true;
                break;
            }
        }
        assertTrue(found, "Deployment event not emitted");
    }

    /// @notice A reverting `initialize` (here identical tokens) bubbles straight
    /// up out of the proxy constructor.
    function testNewMorphoPairOraclePropagatesInitRevert() external {
        MorphoPairOracleBeaconSetDeployer bsd = _deployBSD();
        vm.expectRevert(ZeroToken.selector);
        bsd.newMorphoPairOracle(address(0), address(quote));
        vm.expectRevert(IdenticalTokens.selector);
        bsd.newMorphoPairOracle(address(base), address(base));
    }

    /// @notice The beacon is genuinely SHARED: deploy two adapters with DISTINCT
    /// pairs, then upgrade the single beacon to a V2 implementation and prove
    /// BOTH proxies retarget (answer the V2-only `version()`), while each proxy
    /// retains its OWN distinct state across the upgrade.
    function testMultipleProxiesShareBeacon() external {
        MorphoPairOracleBeaconSetDeployer bsd = _deployBSD();

        MockERC20Decimals base2 = new MockERC20Decimals(8);
        MorphoPairOracle a = bsd.newMorphoPairOracle(address(base), address(quote));
        MorphoPairOracle b = bsd.newMorphoPairOracle(address(base2), address(quote));
        assertTrue(address(a) != address(b), "proxies must be distinct");

        bytes32 pairA = central.pairId(address(base), address(quote));
        bytes32 pairB = central.pairId(address(base2), address(quote));

        address beacon = address(bsd.I_MORPHO_PAIR_ORACLE_BEACON());

        // V1 has no `version()` — both proxies revert on it pre-upgrade.
        (bool okA,) = address(a).staticcall(abi.encodeWithSignature("version()"));
        (bool okB,) = address(b).staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okA, "V1 has no version() (a)");
        assertFalse(okB, "V1 has no version() (b)");

        // One beacon upgrade retargets EVERY proxy off that beacon.
        MorphoPairOracleV2 v2Impl = new MorphoPairOracleV2(central);
        vm.prank(BEACON_OWNER);
        UpgradeableBeacon(beacon).upgradeTo(address(v2Impl));

        assertEq(MorphoPairOracleV2(address(a)).version(), 2, "proxy a retargeted");
        assertEq(MorphoPairOracleV2(address(b)).version(), 2, "proxy b retargeted");

        // Each proxy retains its OWN distinct state across the upgrade.
        assertEq(a.pairId(), pairA, "proxy a keeps its own pairId");
        assertEq(b.pairId(), pairB, "proxy b keeps its own pairId");
        _push(pairA, 42e18, block.timestamp);
        assertEq(a.price(), 42e24, "still rescales the central price");
    }

    // -------- Helpers --------

    function _digest(bytes32 id, uint256 price, uint256 timestamp) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(central.PRICE_UPDATE_TYPEHASH(), id, price, timestamp));
        return keccak256(abi.encodePacked("\x19\x01", central.domainSeparator(), structHash));
    }

    function _sign(bytes32 id, uint256 price, uint256 timestamp) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, _digest(id, price, timestamp));
        return abi.encodePacked(r, s, v);
    }

    function _push(bytes32 id, uint256 price, uint256 timestamp) internal {
        assertTrue(central.updatePrice(id, price, timestamp, _sign(id, price, timestamp)));
    }
}
