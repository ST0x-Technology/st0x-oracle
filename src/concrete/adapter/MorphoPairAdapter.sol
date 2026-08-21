// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin-contracts-5.6.1/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin-contracts-5.6.1/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin-contracts-5.6.1/utils/math/Math.sol";

import {IOracle} from "../../interface/IOracle.sol";
import {ST0xPriceOracle} from "../oracle/ST0xPriceOracle.sol";

/// @dev Error raised when a zero address is provided for a pair token.
error ZeroToken();

/// @dev Error raised when the base and quote token are the same address. A
/// pair prices one token in terms of a different one; an identical pair is a
/// configuration error.
error IdenticalTokens();

/// @dev The rescaled Morpho price floored to zero even though the central store
/// served a valid non-zero price. Reachable only for collateral tokens whose
/// decimals make the net Morpho exponent deeply negative (`baseDecimals > 18 +
/// quoteDecimals`). Feeding Morpho a zero here would value the collateral at
/// nothing (fail-OPEN — every position unhealthy), the exact outcome the
/// central store's own `PriceZero` guard prevents, so the adapter fails CLOSED
/// instead: the read reverts and the market freezes rather than mispricing.
/// @param central The non-zero central price that rescaled to zero.
error PriceRoundsToZero(uint256 central);

/// @dev The live vault NAV ratio no longer matches the ratio the stored
/// central price was computed against. There is no valid price for this
/// market until the publisher signs one against the current ratio, so every
/// pricing path (health checks and liquidations alike) fails closed until
/// that update lands — the intended behaviour across a vault distribution,
/// not an outage.
/// @param storedRatio The ratio the central price was computed against.
/// @param liveRatio The vault's current `convertToAssets(NAV_RATIO_SHARES)`.
error RatioMismatch(uint256 storedRatio, uint256 liveRatio);

/// @dev The stored central price carries a non-zero NAV ratio but the
/// collateral token could not be probed for a live one (no code, a reverting
/// `convertToAssets`, or malformed return data). The adapter never serves a
/// price whose ratio it cannot verify, so the read fails closed.
/// @param baseToken The collateral token that failed the ratio probe.
/// @param storedRatio The ratio the central price was computed against.
error UnverifiableRatio(address baseToken, uint256 storedRatio);

/// @dev The collateral token probes as a live wt-vault but the stored central
/// price carries the zero "no ratio" sentinel. A real NAV ratio is never
/// zero, so a vault-collateral price without the ratio it was computed
/// against is not a price — the sentinel is only for markets whose collateral
/// is not a vault at all. The read fails closed until the publisher signs a
/// ratio-carrying update; while it does, this market's pricing (health checks
/// and liquidations alike) freezes, exactly as in the `RatioMismatch` case.
/// @param baseToken The vault collateral whose price arrived without a ratio.
/// @param liveRatio The vault's current `convertToAssets(NAV_RATIO_SHARES)`.
error NavRatioMissing(address baseToken, uint256 liveRatio);

/// @title MorphoPairAdapter
/// @notice Beacon-proxied adapter binding one Morpho Blue market to one pair
/// on the central `ST0xPriceOracle`, converting the central store's
/// publisher-scaled value into Morpho Blue's `price()` convention.
///
/// # The scale contract (cross-repo)
///
/// `ST0xPriceOracle` treats stored values as opaque — scaling belongs to the
/// publisher/consumer of each pair. This adapter fixes that convention for
/// its markets: the off-chain publisher MUST sign, for `pairId(base, quote)`,
/// the price of one whole `base` (Morpho *collateral*) token denominated in
/// whole `quote` (Morpho *loan*) tokens, scaled to `PUBLISHER_DECIMALS`
/// (1e18). This constant is the explicit, versioned contract the separate
/// publisher repo must honour — the previous "forward the opaque value
/// verbatim" behaviour left the 36-decimal Morpho invariant as an unpinned
/// social agreement across three parties.
///
/// # Morpho Blue's convention
///
/// `IOracle.price()` must return the price of one collateral token in loan
/// token, scaled by `1e36 * 10^loanDecimals / 10^collateralDecimals`. With
/// `base` = collateral and `quote` = loan, and the publisher signing an
/// 18-decimal whole-token ratio `signed`:
///
///   price() = signed * 10^(36 + quoteDecimals - baseDecimals - 18)
///           = mulDiv(signed, 10^(36 + quoteDecimals), 10^(baseDecimals + 18))
///
/// The numerator/denominator form keeps both exponents non-negative and does
/// the division last (no precision loss beyond the final integer floor). Both
/// scale factors are precomputed once at `initialize` from the tokens'
/// on-chain `decimals()` and stored, so `price()` is a single `mulDiv`.
///
/// # The NAV-ratio gate
///
/// The central store serves each price atomically with the vault NAV ratio
/// it was computed against, ZERO being its "no ratio" sentinel. The store is
/// an opaque carrier — it only sees pairIds and cannot know whether a pair's
/// base is a vault — but this adapter CAN know: it holds the collateral
/// token address. Every `price()` read therefore starts by probing
/// `convertToAssets(NAV_RATIO_SHARES)` on the collateral to classify the
/// market (one extra staticcall per read, paid deliberately so the gate is
/// symmetric), then applies the full truth table:
///
///  - vault collateral, non-zero stored ratio → the live probe must EXACTLY
///    equal the stored ratio (`RatioMismatch` otherwise);
///  - vault collateral, ZERO stored ratio → `NavRatioMissing` — a real NAV
///    ratio is never zero, so a vault price without its ratio is not a
///    price;
///  - non-vault collateral (probe fails), zero ratio → genuinely ratio-less
///    market, priced normally;
///  - non-vault collateral, non-zero ratio → `UnverifiableRatio` — the
///    adapter never serves a price whose ratio it cannot verify.
///
/// Both revert quadrants freeze this market's pricing — health checks AND
/// liquidations — until the publisher's next well-formed update: across a
/// vault distribution (mismatch), or for as long as a vault market's
/// publisher omits the ratio (missing). Intended fail-closed windows, not
/// outages: Morpho has no way to consume a price the publisher priced
/// against a NAV that no longer exists, or a vault price whose NAV binding
/// was never published.
///
/// Every market's adapter is a `BeaconProxy` over one shared
/// `UpgradeableBeacon`, so a single beacon upgrade retargets all deployed
/// adapters at once. The central oracle address is an implementation immutable
/// (chain-constant, shared by every proxy); per-market state is namespaced
/// ERC-7201 storage set once in `initialize`.
contract MorphoPairAdapter is Initializable, IOracle {
    /// @notice The decimal scale the off-chain publisher MUST sign every price
    /// for a MorphoPairAdapter pair at: `signed = wholeQuotePerWholeBase * 1e18`.
    /// This is the load-bearing cross-repo contract between the publisher and
    /// this adapter — do not change without coordinating the publisher.
    uint256 public constant PUBLISHER_DECIMALS = 18;

    /// @notice The share amount the NAV ratio is quoted for:
    /// `convertToAssets(NAV_RATIO_SHARES)` on the wt-vault collateral token
    /// is the value the publisher signs into `PricePoint.ratio` and the value
    /// this adapter asserts the live vault still reports. Part of the same
    /// cross-repo convention as `PUBLISHER_DECIMALS`.
    uint256 public constant NAV_RATIO_SHARES = 1e18;

    /// @notice The central multi-pair price store this adapter reads —
    /// chain-constant, shared by all beacon proxies, hence an
    /// implementation immutable.
    ST0xPriceOracle public immutable iCentral;

    /// @custom:storage-location erc7201:st0x.morphopairadapter.main
    struct MainStorage {
        // The Morpho collateral token (`base`) this adapter prices.
        address baseToken;
        // The Morpho loan token (`quote`) prices are denominated in.
        address quoteToken;
        // iCentral.pairId(baseToken, quoteToken), cached at init.
        bytes32 pairId;
        // 10^(36 + quoteDecimals) — the Morpho-scale numerator.
        uint256 scaleNumerator;
        // 10^(baseDecimals + PUBLISHER_DECIMALS) — the Morpho-scale denominator.
        uint256 scaleDenominator;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.morphopairadapter.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x74b4f4941730157fbb9029e5ac16504bafcfacccce2e3df7268ce3b41dcfcc00;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    error ZeroCentral();

    constructor(ST0xPriceOracle central) {
        if (address(central) == address(0)) revert ZeroCentral();
        iCentral = central;
        _disableInitializers();
    }

    /// @notice Initialise one beacon proxy for a Morpho market pair.
    /// @param base The Morpho collateral token being priced. Reverts
    /// `ZeroToken` if zero, `IdenticalTokens` if equal to `quote`.
    /// @param quote The Morpho loan token prices are denominated in.
    /// @dev Reads both tokens' `decimals()` and precomputes the Morpho scale
    /// factors. A token whose `decimals()` is absurdly large makes the
    /// `10 ** ...` overflow and reverts here — fail-closed at init rather than
    /// minting an always-reverting adapter. The exact fail-closed boundaries
    /// are `quoteDecimals >= 42` (numerator `10^(36 + quoteDecimals)` exceeds
    /// `2^256`) and `baseDecimals >= 60` (denominator `10^(baseDecimals + 18)`
    /// exceeds `2^256`); both surface as an arithmetic-overflow panic.
    /// @dev Surviving init does NOT guarantee `price()` can never overflow.
    /// A quote token with e.g. 41 decimals passes here (`10^77 < 2^256`) but
    /// leaves `scaleNumerator ~= 1e77`, and `price()`'s
    /// `mulDiv(central, scaleNumerator, scaleDenominator)` can then exceed
    /// `2^256` for a normal central value when `scaleDenominator` is small —
    /// bricking that market (fail-closed revert, never a wrong price). This is
    /// only reachable with pathological 40+ decimal tokens; operators MUST bind
    /// only real, sane-decimal (`<= ~18`) tokens.
    function initialize(address base, address quote) external initializer {
        if (base == address(0) || quote == address(0)) revert ZeroToken();
        if (base == quote) revert IdenticalTokens();

        uint256 baseDecimals = IERC20Metadata(base).decimals();
        uint256 quoteDecimals = IERC20Metadata(quote).decimals();

        MainStorage storage $ = _main();
        $.baseToken = base;
        $.quoteToken = quote;
        $.pairId = iCentral.pairId(base, quote);
        $.scaleNumerator = 10 ** (36 + quoteDecimals);
        $.scaleDenominator = 10 ** (baseDecimals + PUBLISHER_DECIMALS);
    }

    /// @notice The Morpho collateral token (`base`) this adapter prices.
    function baseToken() external view returns (address) {
        return _main().baseToken;
    }

    /// @notice The Morpho loan token (`quote`) prices are denominated in.
    function quoteToken() external view returns (address) {
        return _main().quoteToken;
    }

    /// @notice The central-store pair id this adapter forwards.
    function pairId() external view returns (bytes32) {
        return _main().pairId;
    }

    /// @inheritdoc IOracle
    /// @dev Reads the publisher-signed 18-decimal value from the central store
    /// (which enforces expiry / unset reverts and serves the price atomically
    /// with the vault NAV ratio it was computed against) and rescales it into
    /// Morpho Blue's `1e36 * 10^loanDec / 10^collDec` convention.
    /// @dev THE RATIO GATES THE PRICE. A price is only valid against the NAV
    /// ratio it was computed at; Morpho has no notion of "use it anyway,
    /// slightly stale", so the only correct behaviour outside the two valid
    /// quadrants is to revert. The read first CLASSIFIES the collateral by
    /// probing its live `convertToAssets(NAV_RATIO_SHARES)` — on EVERY read,
    /// including the zero-ratio path, one extra staticcall paid deliberately
    /// so vault-ness is established before the sentinel is trusted — then
    /// applies the truth table (see the contract NatSpec, "The NAV-ratio
    /// gate"): a probed vault requires a non-zero stored ratio
    /// (`NavRatioMissing`) that EXACTLY equals the live one
    /// (`RatioMismatch`); a non-vault collateral requires the zero sentinel
    /// (`UnverifiableRatio` otherwise). The ratio is piecewise-constant — it
    /// steps only at vault distributions — so exact matching rejects nothing
    /// in normal operation; from a distribution (or a publisher omitting the
    /// ratio on a vault market) until the next well-formed update this
    /// market's pricing (health checks AND liquidations) reverts, which is
    /// the intended fail-closed window, not an outage.
    /// @dev `Math.mulDiv` floors (rounds DOWN). This is deliberate and MUST NOT
    /// change: the result is the Morpho *collateral* price, and under-stating
    /// collateral is the conservative direction (less borrowing power, earlier
    /// liquidation) that favours the lender/protocol. A `Ceil` variant would
    /// silently reverse this safety property. The one place flooring is unsafe
    /// is when it collapses a valid non-zero central price all the way to zero
    /// (deeply negative net exponent, i.e. very-high-decimal collateral): a zero
    /// collateral price is fail-OPEN in Morpho, so guard it and fail closed.
    function price() external view returns (uint256) {
        MainStorage storage $ = _main();
        (uint256 central, uint256 ratio) = iCentral.price($.pairId);
        address base = $.baseToken;
        // Low-level staticcall rather than a typed call so every probe
        // failure — no code at the token, a reverting implementation, or
        // malformed return data — uniformly classifies the collateral as
        // not-a-vault instead of bubbling an opaque revert.
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory data) = base.staticcall(abi.encodeCall(IERC4626.convertToAssets, (NAV_RATIO_SHARES)));
        if (ok && data.length == 32) {
            uint256 liveRatio = abi.decode(data, (uint256));
            if (ratio == 0) revert NavRatioMissing(base, liveRatio);
            if (liveRatio != ratio) revert RatioMismatch(ratio, liveRatio);
        } else if (ratio != 0) {
            revert UnverifiableRatio(base, ratio);
        }
        uint256 scaled = Math.mulDiv(central, $.scaleNumerator, $.scaleDenominator);
        if (scaled == 0) revert PriceRoundsToZero(central);
        return scaled;
    }
}
