// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

// `Test` itself arrives via SignedPriceTestBase (which is `is Test`); only
// `stdError` needs naming here, for the arithmetic-revert expectations below.
import {stdError} from "forge-std-1.16.1/src/Test.sol";
import {SignedPriceTestBase} from "../../lib/SignedPriceTestBase.sol";

import {UpgradeableBeacon} from "@openzeppelin-contracts-5.6.1/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";

import {ST0xPriceOracle} from "../../../../src/concrete/oracle/ST0xPriceOracle.sol";
import {
    MorphoPairAdapter,
    ZeroToken,
    IdenticalTokens,
    PriceRoundsToZero
} from "../../../../src/concrete/adapter/MorphoPairAdapter.sol";
import {MorphoPairAdapterV2} from "../../../mocks/MorphoPairAdapterV2.sol";
import {MockERC20Decimals} from "../../../mocks/MockERC20Decimals.sol";

/// @title MorphoPairAdapterTest
/// @notice Unit coverage for the `MorphoPairAdapter` beacon-proxied adapter:
/// the publisher-scale → Morpho-convention rescale (known-answer), central
/// expiry/unset passthrough, constructor / initializer guards, and the
/// shared beacon upgrade retargeting every deployed adapter proxy at once.
contract MorphoPairAdapterTest is SignedPriceTestBase {
    // SIGNER_PK / SIGNER are inherited from SignedPriceTestBase.
    address constant ADMIN = address(0xC0DE);

    // base = Morpho collateral (18 dec), quote = Morpho loan (6 dec, USDC-like).
    MockERC20Decimals base;
    MockERC20Decimals quote;
    bytes32 PAIR_A;

    ST0xPriceOracle oracle;
    UpgradeableBeacon adapterBeacon;

    function setUp() public {
        // Same shape as production: implementation behind a beacon proxy.
        ST0xPriceOracle impl = new ST0xPriceOracle();
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(impl), ADMIN);
        oracle = ST0xPriceOracle(
            address(
                new BeaconProxy(address(beacon), abi.encodeCall(ST0xPriceOracle.initialize, (ADMIN, ADMIN, SIGNER)))
            )
        );

        // The adapter beacon, shared by every MorphoPairAdapter proxy.
        MorphoPairAdapter adapterImpl = new MorphoPairAdapter(oracle);
        adapterBeacon = new UpgradeableBeacon(address(adapterImpl), ADMIN);

        base = new MockERC20Decimals(18);
        quote = new MockERC20Decimals(6);
        PAIR_A = oracle.pairId(address(base), address(quote));
    }

    /// @notice Known-answer scale test. Publisher signs an 18-dp whole-token
    /// ratio; the adapter must return Morpho's `1e36 * 10^loanDec / 10^collDec`
    /// value. base=18dec (collateral), quote=6dec (loan), signed = 42e18 (42.0
    /// loan per collateral) ⇒ price() = 42 * 10^(36 + 6 - 18) = 42e24.
    function test_MorphoPairAdapter_RescalesToMorphoConvention() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        assertEq(adapter.pairId(), PAIR_A, "pairId wired");
        assertEq(adapter.baseToken(), address(base), "base wired");
        assertEq(adapter.quoteToken(), address(quote), "quote wired");

        _push(PAIR_A, 42e18, block.timestamp);
        assertEq(adapter.price(), 42e24, "42.0 loan/collateral in Morpho scale");
    }

    /// @notice A pair with equal base/quote decimals leaves the value at the
    /// bare 1e36 Morpho scale: signed 1e18 (1.0) ⇒ price() = 1e36.
    function test_MorphoPairAdapter_EqualDecimals_BareScale() public {
        MockERC20Decimals base18 = new MockERC20Decimals(18);
        MockERC20Decimals quote18 = new MockERC20Decimals(18);
        MorphoPairAdapter adapter = _deployAdapter(address(base18), address(quote18));
        bytes32 id = oracle.pairId(address(base18), address(quote18));
        _push(id, 1e18, block.timestamp);
        assertEq(adapter.price(), 1e36, "1.0 at equal decimals is bare 1e36");
    }

    /// @notice Central expiry / unset reverts pass straight through the
    /// rescale — the adapter never masks them. The adapter needs no staleness
    /// logic of its own: it calls `price()`, which refuses a stored price at
    /// its publisher-signed expiry, and the revert bubbles to Morpho.
    function test_MorphoPairAdapter_CentralRevertsPassThrough() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));

        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceUnset.selector, PAIR_A));
        adapter.price();

        _push(PAIR_A, 42e18, block.timestamp);
        vm.warp(block.timestamp + DEFAULT_VALIDITY);
        vm.expectRevert(abi.encodeWithSelector(ST0xPriceOracle.PriceExpired.selector, PAIR_A));
        adapter.price();
    }

    function test_MorphoPairAdapter_ZeroCentral_Reverts() public {
        vm.expectRevert(MorphoPairAdapter.ZeroCentral.selector);
        new MorphoPairAdapter(ST0xPriceOracle(address(0)));
    }

    function test_MorphoPairAdapter_ZeroToken_Reverts() public {
        vm.expectRevert(ZeroToken.selector);
        _deployAdapter(address(0), address(quote));
        vm.expectRevert(ZeroToken.selector);
        _deployAdapter(address(base), address(0));
    }

    function test_MorphoPairAdapter_IdenticalTokens_Reverts() public {
        vm.expectRevert(IdenticalTokens.selector);
        _deployAdapter(address(base), address(base));
    }

    /// @notice Fail-closed at init: a quote (loan) token with absurdly large
    /// `decimals()` makes `scaleNumerator = 10 ** (36 + quoteDecimals)`
    /// overflow uint256, reverting init with an arithmetic panic rather than
    /// minting an always-reverting adapter. The boundary is `quoteDecimals >=
    /// 42` (`10^78 > 2^256`); pins the NatSpec "fail-closed" safety claim.
    function test_MorphoPairAdapter_AbsurdQuoteDecimals_RevertsAtInit() public {
        MockERC20Decimals hugeQuote = new MockERC20Decimals(42);
        vm.expectRevert(stdError.arithmeticError);
        _deployAdapter(address(base), address(hugeQuote));
    }

    /// @notice Fail-closed at init on the denominator side: a base (collateral)
    /// token with absurdly large `decimals()` makes `scaleDenominator = 10 **
    /// (baseDecimals + 18)` overflow uint256. The boundary is `baseDecimals >=
    /// 60` (`10^78 > 2^256`).
    function test_MorphoPairAdapter_AbsurdBaseDecimals_RevertsAtInit() public {
        MockERC20Decimals hugeBase = new MockERC20Decimals(60);
        vm.expectRevert(stdError.arithmeticError);
        _deployAdapter(address(hugeBase), address(quote));
    }

    /// @notice Rounding-direction pin (#265). When the net Morpho exponent is
    /// negative the rescale divides, and `Math.mulDiv` MUST floor (round DOWN)
    /// — the conservative direction for a Morpho collateral price. base=30dec
    /// (collateral), quote=6dec (loan) ⇒ net exponent 36 + 6 - 30 - 18 = -6, so
    /// price() = floor(central / 1e6). A non-divisible central value that would
    /// give 1 flooring vs 2 ceiling discriminates the direction.
    function test_MorphoPairAdapter_PriceFloorsDown() public {
        MockERC20Decimals base30 = new MockERC20Decimals(30);
        MorphoPairAdapter adapter = _deployAdapter(address(base30), address(quote));
        bytes32 id = oracle.pairId(address(base30), address(quote));
        // 1_999_999 / 1e6 = 1.999999 → floors to 1 (ceil would be 2).
        _push(id, 1_999_999, block.timestamp);
        assertEq(adapter.price(), 1, "mulDiv must floor (round DOWN), not ceil");
    }

    /// @notice The NatSpec pins the rescale as `mulDiv(signed, 10^(36 +
    /// quoteDecimals), 10^(baseDecimals + 18))` and claims the form "does the
    /// division last (no precision loss beyond the final integer floor)". That
    /// is only true because `Math.mulDiv` carries a FULL-WIDTH (512-bit)
    /// intermediate: a plain `(signed * numerator) / denominator` reverts
    /// whenever the product exceeds `2^256`, even when the quotient fits
    /// comfortably. base=18dec / quote=6dec ⇒ numerator 10^42, denominator
    /// 10^36. A central value of 1e40 makes the product 1e82 — far past `2^256`
    /// (~1.16e77) — while the true quotient 1e40 * 10^(36+6-18-18) = 1e46 is a
    /// perfectly ordinary uint256. Serving it proves the intermediate is not
    /// truncated to 256 bits.
    function test_MorphoPairAdapter_MulDivCarriesFullWidthIntermediate() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        _push(PAIR_A, 1e40, block.timestamp);
        assertEq(adapter.price(), 1e46, "product overflows 256 bits; the quotient must still be served");
    }

    /// @notice Fail-closed at READ time, the counterpart to the init-time
    /// decimals guards. The NatSpec is explicit that surviving `initialize`
    /// does not guarantee `price()` can never overflow, and that when it does
    /// the market is "bricked (fail-closed revert, never a wrong price)". Pin
    /// the revert: base=18dec / quote=6dec rescales by 10^6, so a central value
    /// of 1e72 implies 1e78 — past `2^256`. `Math.mulDiv` must panic rather
    /// than wrap and hand Morpho a silently-truncated collateral price.
    function test_MorphoPairAdapter_PriceOverflow_FailsClosedNotWrapped() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        _push(PAIR_A, 1e72, block.timestamp);
        vm.expectRevert(stdError.arithmeticError);
        adapter.price();
    }

    /// @notice The NatSpec states the EXACT fail-closed decimals boundaries as
    /// `quoteDecimals >= 42` and `baseDecimals >= 60`. The two
    /// `AbsurdDecimals` tests pin the rejected side (42 / 60); this pins the
    /// ACCEPTED side, so a boundary that silently tightens to 41 / 59 (or a
    /// wrong exponent constant on either side) is caught. Both known answers
    /// are re-derived from Morpho's convention, not from the implementation:
    ///  - base 18dec, quote 41dec: 1.0 signed as 1e18 ⇒ 1e18 * 10^(36+41-18-18)
    ///    = 10^59.
    ///  - base 59dec, quote 6dec: central 1e40 ⇒ 1e40 * 10^(36+6-59-18) = 1e5.
    function test_MorphoPairAdapter_DecimalsAcceptanceBoundary() public {
        MockERC20Decimals quote41 = new MockERC20Decimals(41);
        MorphoPairAdapter maxQuote = _deployAdapter(address(base), address(quote41));
        bytes32 idQ = oracle.pairId(address(base), address(quote41));
        _push(idQ, 1e18, block.timestamp);
        assertEq(maxQuote.price(), 10 ** 59, "quoteDecimals 41 is the largest accepted");

        MockERC20Decimals base59 = new MockERC20Decimals(59);
        MorphoPairAdapter maxBase = _deployAdapter(address(base59), address(quote));
        bytes32 idB = oracle.pairId(address(base59), address(quote));
        _push(idB, 1e40, block.timestamp);
        assertEq(maxBase.price(), 1e5, "baseDecimals 59 is the largest accepted");
    }

    /// @notice A valid, fresh, non-zero central price that the decimal rescale
    /// FLOORS all the way to zero must fail closed (revert `PriceRoundsToZero`),
    /// not return 0. Morpho reading a zero collateral price treats the
    /// collateral as worthless — every position unhealthy — which is the
    /// fail-OPEN outcome the central store's own `PriceZero` guard exists to
    /// prevent, arriving through the adapter instead. Reachable for very-high-
    /// decimal collateral (`baseDecimals > 18 + quoteDecimals`): base 59 /
    /// quote 6 scales by `10^(36+6-59-18) = 10^-35`, so the canonical 1.0 price
    /// (`1e18`) floors to 0. Issue: signed-price C2.
    function test_MorphoPairAdapter_PriceRoundingToZeroFailsClosed() public {
        MockERC20Decimals base59 = new MockERC20Decimals(59);
        MorphoPairAdapter adapter = _deployAdapter(address(base59), address(quote));
        bytes32 id = oracle.pairId(address(base59), address(quote));
        // Canonical 1.0 — a perfectly valid, fresh central price.
        _push(id, 1e18, block.timestamp);
        assertEq(oracle.price(id), 1e18, "central serves a valid non-zero price");
        vm.expectRevert(abi.encodeWithSelector(PriceRoundsToZero.selector, uint256(1e18)));
        adapter.price();
    }

    function test_MorphoPairAdapter_InitializeOnlyOnce() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(address(base), address(quote));
    }

    function test_MorphoPairAdapter_ImplementationInitializersDisabled() public {
        MorphoPairAdapter impl = new MorphoPairAdapter(oracle);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(base), address(quote));
    }

    /// @notice The `MainStorage` slot constant is a hardcoded hex literal.
    /// Pin it to the ERC-7201 derivation: after init, the first field
    /// (`baseToken`) must be readable at the recomputed slot.
    function test_MorphoPairAdapter_MainStorageLocationMatchesErc7201Derivation() public {
        MorphoPairAdapter adapter = _deployAdapter(address(base), address(quote));
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("st0x.morphopairadapter.main")) - 1)) & ~bytes32(uint256(0xff));
        address storedBase = address(uint160(uint256(vm.load(address(adapter), derived))));
        assertEq(storedBase, adapter.baseToken(), "MainStorage must be at the ERC-7201 derived slot");
    }

    /// @notice One shared-beacon upgrade retargets EVERY deployed adapter
    /// proxy at once, with per-proxy state and the implementation immutable
    /// (`iCentral`) surviving the upgrade.
    function test_MorphoPairAdapter_BeaconUpgradeRetargetsAllProxies() public {
        MockERC20Decimals base2 = new MockERC20Decimals(8);
        MorphoPairAdapter adapterA = _deployAdapter(address(base), address(quote));
        MorphoPairAdapter adapterB = _deployAdapter(address(base2), address(quote));
        bytes32 pairB = oracle.pairId(address(base2), address(quote));

        // V1 has no `version()` — both proxies revert on it pre-upgrade.
        (bool okBefore,) = address(adapterA).staticcall(abi.encodeWithSignature("version()"));
        assertFalse(okBefore, "V1 has no version()");

        // One beacon upgrade...
        MorphoPairAdapterV2 v2Impl = new MorphoPairAdapterV2(oracle);
        vm.prank(ADMIN);
        adapterBeacon.upgradeTo(address(v2Impl));

        // ...retargets ALL deployed adapters.
        assertEq(MorphoPairAdapterV2(address(adapterA)).version(), 2, "adapter A retargeted");
        assertEq(MorphoPairAdapterV2(address(adapterB)).version(), 2, "adapter B retargeted");

        // Per-proxy state survives the upgrade and forwarding still works.
        assertEq(adapterA.pairId(), PAIR_A, "adapter A proxy state intact");
        assertEq(adapterB.pairId(), pairB, "adapter B proxy state intact");
        assertEq(address(adapterA.iCentral()), address(oracle), "central immutable intact");
        _push(PAIR_A, 42e18, block.timestamp);
        assertEq(adapterA.price(), 42e24, "still rescales the central price");

        // Known-answer for the only 8-dec-collateral / 6-dec-loan pair in the
        // suite. Publisher signs the whole-token ratio 42.0 as 42e18; the
        // adapter rescales by num/denom = 10^(36+6) / 10^(8+18), so
        // price() = 42e18 * 10^42 / 10^26 = 42 * 10^34. Catches an exponent
        // sign error that only shows when baseDecimals is neither 18 nor equal
        // to quoteDecimals.
        _push(pairB, 42e18, block.timestamp);
        assertEq(adapterB.price(), 42 * 10 ** 34, "8-dec collateral / 6-dec loan rescale");
    }

    // -------- Helpers --------

    function _deployAdapter(address baseToken, address quoteToken) internal returns (MorphoPairAdapter) {
        return MorphoPairAdapter(
            address(
                new BeaconProxy(
                    address(adapterBeacon), abi.encodeCall(MorphoPairAdapter.initialize, (baseToken, quoteToken))
                )
            )
        );
    }

    function _push(bytes32 id, uint256 price, uint256 timestamp) internal {
        push(oracle, id, price, timestamp);
    }
}
