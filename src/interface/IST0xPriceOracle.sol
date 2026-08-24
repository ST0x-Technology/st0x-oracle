// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title IST0xPriceOracle
/// @notice The consumer-facing surface of `ST0xPriceOracle` — the singleton
/// multi-pair signed price store. This is the interface downstream consumers
/// (venues, adapters, pushers) import or mirror instead of hand-copying
/// signatures from the concrete contract.
///
/// It exists because hand-copied signatures drift SILENTLY when only return
/// types change: `price(bytes32)` grew from `returns (uint256)` to
/// `returns (uint256 storedPrice, uint256 storedRatio)` and kept the same
/// selector, so a consumer holding the old copy still resolves the call and
/// quietly decodes only the first return word — dropping the NAV ratio that
/// gates the price. `ST0xPriceOracle is IST0xPriceOracle`, so the compiler
/// pins the concrete contract to these exact signatures; a surface change
/// must edit this file, which is the visible diff consumers can track.
///
/// The surface here is the PERMISSIONLESS one: reads, the deterministic
/// `pairId` helper, and `updatePrice` (open submission — the publisher's
/// EIP-712 signature authorises, not the caller, and a consumer may push a
/// signed price in the same transaction that consumes it). The role-gated
/// lifecycle (`initialize`, `setSigner`) is deployment/governance surface,
/// deliberately omitted — consumers must not depend on it.
///
/// Value semantics: prices and ratios are opaque `uint256`s; scaling belongs
/// to each pair's publisher/consumer contract, never to this store.
interface IST0xPriceOracle {
    /// @notice The canonical pair id: base token first, quote token second,
    /// plain concatenation (`keccak256(abi.encodePacked(baseToken,
    /// quoteToken))`). Deterministic — no registration step exists;
    /// consumers and publishers derive the same id independently. The two
    /// orderings of a token pair are two DIFFERENT pair ids with independent
    /// stored state.
    function pairId(address baseToken, address quoteToken) external pure returns (bytes32);

    /// @notice Push a signed price for a pair. Open — anyone may submit; the
    /// global publisher's EIP-712 signature over
    /// (pairId, price, timestamp, expiry, ratio) is what authorises. See the
    /// concrete contract for the full acceptance predicate; the shape of the
    /// contract is: a not-strictly-newer payload is a NO-OP returning
    /// `false` (never a revert, so a lost update race cannot brick a
    /// surrounding call), and every degenerate payload — future-stamped,
    /// already-expired, oversized validity window, zero price, bad
    /// signature — reverts. No unsigned, malformed or expired payload is
    /// ever applied.
    /// @param id The pair id the payload is signed over.
    /// @param newPrice The opaque price value (publisher-scaled). Zero
    /// reverts.
    /// @param newTimestamp The publisher's observation timestamp — the
    /// per-pair replay-ordering key (strictly newer applies).
    /// @param newExpiry The publisher-signed validity horizon; the price is
    /// dead at and past this instant.
    /// @param newRatio The vault NAV ratio the price was computed against.
    /// ZERO means "no ratio" (a non-vault pair) and is a valid signed value,
    /// not a degenerate one.
    /// @param signature The publisher's EIP-712 signature over the payload.
    /// @return applied `true` if the update was strictly newer and stored;
    /// `false` for the deliberate not-strictly-newer no-op.
    function updatePrice(
        bytes32 id,
        uint256 newPrice,
        uint256 newTimestamp,
        uint256 newExpiry,
        uint256 newRatio,
        bytes calldata signature
    ) external returns (bool applied);

    /// @notice The checked read: the stored price AND the vault NAV ratio it
    /// was priced against, as ONE atomic point. The ratio gates the price —
    /// if the live vault ratio no longer matches the one the price was
    /// computed against, there IS no valid price — so no checked read serves
    /// a price without its ratio; a consumer carries the ratio to settlement
    /// and asserts it against the live vault there.
    ///
    /// Reverts `PriceUnset` when no update has ever landed and `PriceExpired`
    /// once `block.timestamp` reaches the stored payload's publisher-signed
    /// `expiry` (the edge instant fails closed). There is no other staleness
    /// bound: the producer's signed horizon is the staleness bound.
    /// @param id The pair id to read.
    /// @return storedPrice The opaque price value.
    /// @return storedRatio The NAV ratio the price was computed against, or
    /// ZERO for "no ratio" (a non-vault pair), meaning the consumer performs
    /// no ratio assertion.
    function price(bytes32 id) external view returns (uint256 storedPrice, uint256 storedRatio);

    /// @notice Raw stored price state (no expiry check) — for publishers
    /// sizing their next timestamp and for off-chain monitoring. Consumers
    /// of this RAW view that serve prices onward MUST apply the expiry
    /// themselves (`block.timestamp < storedExpiry`, fail closed), exactly
    /// as `price()` does, and MUST carry `storedRatio` with the price.
    /// @param id The pair id to read.
    /// @return storedPrice The last accepted value (0 if never set).
    /// @return storedTimestamp The publisher's observation timestamp for it
    /// (0 if never set).
    /// @return storedExpiry The publisher-signed validity horizon: the
    /// instant AT and past which the price is dead (0 if never set).
    /// @return storedRatio The vault NAV ratio the price was computed
    /// against, or ZERO for "no ratio".
    function pairPrice(bytes32 id)
        external
        view
        returns (uint256 storedPrice, uint256 storedTimestamp, uint256 storedExpiry, uint256 storedRatio);

    /// @notice The global publisher key whose ECDSA signature authorises
    /// every price update.
    function signer() external view returns (address);

    /// @notice EIP-712 domain separator — used by publishers / tests. A
    /// constant: the domain binds name + version only, so signed payloads
    /// replay across chains and deployments by design.
    function domainSeparator() external pure returns (bytes32);
}
