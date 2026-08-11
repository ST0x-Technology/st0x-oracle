// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";

import {ST0xPriceOracle} from "../../../src/concrete/oracle/ST0xPriceOracle.sol";

/// @title SignedPriceTestBase
/// @notice Shared test base holding the single canonical EIP-712 signing
/// implementation for `ST0xPriceOracle` price updates. Every concrete test
/// that needs to forge a signed `updatePrice` payload inherits this so the
/// digest derivation (`PRICE_UPDATE_TYPEHASH` struct hash + `\x19\x01`
/// domain-separator packing) lives in exactly one place. If the signing
/// scheme ever changes, this is the only helper to update and every inheriting
/// suite recompiles against it — no silent per-file drift.
abstract contract SignedPriceTestBase is Test {
    /// @notice The canonical test publisher private key, and its address. Held
    /// here so every signed-price suite shares one signer fixture rather than
    /// re-declaring it — the key/address counterpart to the single `push` /
    /// `signPriceUpdate` helpers below.
    uint256 internal constant SIGNER_PK = uint256(keccak256("st0x.price-oracle.signer.test"));
    address internal immutable SIGNER = vm.addr(SIGNER_PK);

    /// @notice The default validity window applied by the expiry-less `push`
    /// overload: `expiry = timestamp + DEFAULT_VALIDITY`. Sized like a real
    /// intraday publisher window (minutes, not hours) so suites that only
    /// need "a currently-valid price" get one without caring about expiry
    /// mechanics; suites that DO care pass an explicit expiry.
    uint256 internal constant DEFAULT_VALIDITY = 5 minutes;

    /// @notice Signs and applies a price update against `store` with the
    /// canonical `SIGNER_PK`, the default validity window
    /// (`timestamp + DEFAULT_VALIDITY`) and a ZERO ratio ("no ratio"),
    /// asserting it was accepted. The convenience flow for suites that need a
    /// valid stored price but are not exercising expiry or NAV-ratio
    /// mechanics.
    /// @param store The oracle to push to.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    function push(ST0xPriceOracle store, bytes32 id, uint256 price, uint256 timestamp) internal {
        push(store, id, price, timestamp, timestamp + DEFAULT_VALIDITY, 0);
    }

    /// @notice As above with an explicit expiry, still pushing the ZERO
    /// "no ratio" sentinel — for suites exercising expiry semantics that
    /// don't care about the NAV-ratio path.
    /// @param store The oracle to push to.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    /// @param expiry The publisher-signed validity horizon.
    function push(ST0xPriceOracle store, bytes32 id, uint256 price, uint256 timestamp, uint256 expiry) internal {
        push(store, id, price, timestamp, expiry, 0);
    }

    /// @notice Signs and applies a price update against `store` with the
    /// canonical `SIGNER_PK` over the full signed struct — explicit expiry
    /// and vault NAV `ratio` — asserting it was accepted. The single push
    /// flow every overload above delegates to.
    /// @param store The oracle to push to.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    /// @param expiry The publisher-signed validity horizon.
    /// @param ratio The vault NAV ratio the price was priced against.
    function push(ST0xPriceOracle store, bytes32 id, uint256 price, uint256 timestamp, uint256 expiry, uint256 ratio)
        internal
    {
        assertTrue(
            store.updatePrice(
                id,
                price,
                timestamp,
                expiry,
                ratio,
                signPriceUpdate(store, SIGNER_PK, id, price, timestamp, expiry, ratio)
            )
        );
    }

    /// @notice Recreates the EIP-712 digest an off-chain signer would sign for
    /// a price update against `store`, taking the oracle store as a parameter
    /// so the derivation is not tied to any one test's local variable name.
    /// Zero-ratio overload for tests that don't exercise the NAV-ratio path.
    function digestFor(ST0xPriceOracle store, bytes32 id, uint256 price, uint256 timestamp, uint256 expiry)
        internal
        view
        returns (bytes32)
    {
        return digestFor(store, id, price, timestamp, expiry, 0);
    }

    /// @notice As above, over the full signed struct including `ratio`.
    /// @param store The oracle whose domain separator and typehash are used.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    /// @param expiry The publisher-signed validity horizon.
    /// @param ratio The vault NAV ratio the price was priced against.
    /// @return The 32-byte EIP-712 digest.
    function digestFor(
        ST0xPriceOracle store,
        bytes32 id,
        uint256 price,
        uint256 timestamp,
        uint256 expiry,
        uint256 ratio
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(store.PRICE_UPDATE_TYPEHASH(), id, price, timestamp, expiry, ratio));
        return keccak256(abi.encodePacked("\x19\x01", store.domainSeparator(), structHash));
    }

    /// @notice Signs a price update for `store` with `pk`, producing the
    /// packed `(r, s, v)` signature `updatePrice` expects. Zero-ratio
    /// overload for tests that don't exercise the NAV-ratio path.
    function signPriceUpdate(
        ST0xPriceOracle store,
        uint256 pk,
        bytes32 id,
        uint256 price,
        uint256 timestamp,
        uint256 expiry
    ) internal view returns (bytes memory) {
        return signPriceUpdate(store, pk, id, price, timestamp, expiry, 0);
    }

    /// @notice As above, over the full signed struct including `ratio`.
    /// @param store The oracle the signature is for.
    /// @param pk The private key to sign with.
    /// @param id The pair id.
    /// @param price The price being pushed.
    /// @param timestamp The observation timestamp.
    /// @param expiry The publisher-signed validity horizon.
    /// @param ratio The vault NAV ratio the price was priced against.
    /// @return The `abi.encodePacked(r, s, v)` signature.
    function signPriceUpdate(
        ST0xPriceOracle store,
        uint256 pk,
        bytes32 id,
        uint256 price,
        uint256 timestamp,
        uint256 expiry,
        uint256 ratio
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digestFor(store, id, price, timestamp, expiry, ratio));
        return abi.encodePacked(r, s, v);
    }
}
