// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Initializable} from "@openzeppelin-contracts-upgradeable-5.6.1/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin-contracts-upgradeable-5.6.1/access/AccessControlUpgradeable.sol";
import {ECDSA} from "@openzeppelin-contracts-5.6.1/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin-contracts-5.6.1/utils/cryptography/MessageHashUtils.sol";

/// @title ST0xPriceOracle
/// @notice Singleton multi-pair price store. Lives behind a beacon proxy:
/// Initializable + AccessControl with ERC-7201 namespaced storage.
///
/// There is NO pair registration: a pair either has a stored price or it
/// doesn't. Pair ids are deterministic —
/// `keccak256(abi.encodePacked(baseToken, quoteToken))`, exposed as the
/// `pairId` pure helper — and the first `updatePrice` on a brand-new pair
/// simply works. The publisher key (`signer`) is GLOBAL, shared by every
/// pair, and rotated via a role-gated setter.
///
/// Price VALUES are opaque `uint256`s: scaling and semantics belong
/// entirely to the publisher / consumer of each pair. Each pair's publisher
/// decides what its values mean; this contract never interprets them.
///
/// PRODUCER-CONTROLLED VALIDITY: every signed payload carries the
/// publisher's own `expiry` — the instant past which the publisher has
/// disowned the price. Validity is therefore a claim MADE BY the price's
/// producer and enforced here, not a constant guessed by this contract or
/// its consumers. Two enforcement points, both fail-closed at the edge
/// instant:
///
///  - SUBMISSION: `updatePrice` rejects a payload whose window has already
///    closed (`expiry <= block.timestamp` reverts `PriceExpired`). Once a
///    payload's window passes it is dead for every deployment, permanently.
///    The set of payloads a submitter can choose between at any instant is
///    only the currently-live windows, so the publisher's window policy —
///    windows that do not overlap, or overlap only by the small margin
///    needed for continuity of service — is what bounds adversarial
///    selection between genuine signed prices. The publisher tunes that
///    bound off-chain, per payload, with nothing to update on-chain: short
///    windows while the underlying market trades, one long window across a
///    close or weekend.
///  - READ: `price()` refuses to serve a stored price past its expiry
///    (`block.timestamp >= expiry` reverts `PriceExpired`). There is no
///    separate consumer-side staleness knob: the producer's signed horizon
///    is the staleness bound.
///
/// `MAX_VALIDITY_WINDOW` caps `expiry - timestamp` at submission — a
/// sanity cap against a wrong-scale signing pipeline, not a security
/// boundary (see the constant's docs).
///
/// `updatePrice` is PERMISSIONLESS — the global publisher's EIP-712
/// signature is what authorises an update, not the caller. Replay
/// protection is the STRICT per-pair timestamp inequality: an update
/// applies only if its timestamp is strictly newer than the stored one. A
/// not-strictly-newer payload is a NO-OP that returns `false` rather than a
/// revert, so callers may push a signed price in the same transaction that
/// consumes it without risking a brick on a lost race. An invalid signature
/// on an otherwise-fresh payload is malformed input and reverts.
///
/// CROSS-CHAIN REPLAY IS DELIBERATE: the EIP-712 domain binds name +
/// version ONLY — no chainId, no verifyingContract — and there is no nonce,
/// so the same signed price payload is valid on every deployment sharing
/// the global signer. One publisher signature fans out to every chain the
/// oracle is deployed on; that is a feature for multi-chain deployment, not
/// an oversight. The signed `expiry` composes with this: the horizon is
/// chain-agnostic wall-clock time, so a payload expires everywhere at the
/// same instant. NOTE the precondition: because `pairId`
/// binds the base and quote token ADDRESSES (`keccak256(abi.encodePacked(
/// baseToken, quoteToken))`), a signature only replays to deployments where
/// the pair's token addresses are IDENTICAL (e.g. deterministic CREATE2
/// addresses). Pairs whose token addresses differ per chain resolve to
/// different `pairId`s and therefore require a per-chain signature; a
/// publisher must not assume one signature covers a pair whose addresses
/// vary by chain.
///
/// Roles:
///  - `DEFAULT_ADMIN_ROLE` — role administration only (granted to `admin`
///    at `initialize`).
///  - `ORACLE_ADMIN_ROLE` — `setSigner`.
contract ST0xPriceOracle is Initializable, AccessControlUpgradeable {
    /// @notice Role gating `setSigner` (rotation of the global publisher
    /// key). Granted to `oracleAdmin` at `initialize`; distinct from
    /// `DEFAULT_ADMIN_ROLE`, which only administers roles and cannot itself
    /// rotate the signer.
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN");

    /// @notice Upper bound on a payload's validity window
    /// (`expiry - timestamp`) at submission. A SANITY CAP against a
    /// systematically wrong-scale signing pipeline (e.g. a milliseconds
    /// expiry where seconds are meant, which would silently disable
    /// staleness) — NOT a security
    /// boundary: an individually fat-fingered expiry is already recoverable
    /// by superseding it with a strictly-newer tight-window payload or by
    /// rotating the signer, but a pipeline that scales every expiry wrong
    /// defeats both recoveries, and this cap fails it closed at the first
    /// submission. Generous by design so it never constrains legitimate
    /// publisher window policy (a long weekend or market holiday is days,
    /// not weeks).
    uint256 public constant MAX_VALIDITY_WINDOW = 30 days;

    /// @notice EIP-712 typehash binding (pairId, price, timestamp, expiry).
    /// No nonce — replay protection is the strict timestamp inequality in
    /// `updatePrice`; `expiry` is the publisher's signed validity horizon
    /// for the price. Schema evolution is carried by this typehash — a
    /// signature over any other field set produces a different struct hash
    /// and cannot validate — so the domain version never needs bumping.
    bytes32 public constant PRICE_UPDATE_TYPEHASH =
        keccak256("PriceUpdate(bytes32 pairId,uint256 price,uint256 timestamp,uint256 expiry)");

    /// @dev The EIP-712 domain separator. The domain deliberately omits
    /// chainId and verifyingContract so a signed price replays across every
    /// chain / deployment (see contract NatSpec):
    /// keccak256(abi.encode(
    ///     keccak256("EIP712Domain(string name,string version)"),
    ///     keccak256("ST0xPriceOracle"),
    ///     keccak256("1")
    /// ))
    bytes32 private constant DOMAIN_SEPARATOR = 0x661a9d4f8ddbbd7ecb90573d81a96060fc99c958049c913cf71722ddcc8ddd48;

    /// @dev Latest accepted price state for one pair.
    struct PricePoint {
        uint256 price;
        uint256 timestamp;
        uint256 expiry;
    }

    /// @custom:storage-location erc7201:st0x.priceoracle.main
    struct MainStorage {
        // ---- global configuration (setSigner) ----
        // Publisher key whose ECDSA signature authorises every price update.
        address signer;
        // ---- per-pair price state (updatePrice) ----
        mapping(bytes32 pairId => PricePoint) prices;
    }

    // keccak256(abi.encode(uint256(keccak256("st0x.priceoracle.main")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MAIN_STORAGE_LOCATION = 0x8bea1968915949cd5f395bf014546362fbf876c96d338f9e38ecadb2c70bcf00;

    function _main() private pure returns (MainStorage storage $) {
        assembly ("memory-safe") {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    error ZeroAdmin();
    error ZeroSigner();
    error PriceUnset(bytes32 pairId);
    error PriceFuture(bytes32 pairId);
    /// @dev Raised in TWO places, one predicate (`expiry <= block.timestamp`,
    /// the edge instant fails closed): at SUBMISSION for a payload whose
    /// validity window has already closed — an expired payload is dead
    /// permanently, no matter that its timestamp beats the stored one — and
    /// at READ for a stored price past its publisher-signed horizon. The two
    /// sites are disambiguated by which function reverted, so one selector
    /// serves both.
    /// @param pairId The pair whose payload or stored price has expired.
    error PriceExpired(bytes32 pairId);
    /// @dev Raised when a payload's validity window (`expiry - timestamp`)
    /// exceeds `MAX_VALIDITY_WINDOW` — the wrong-scale-pipeline sanity cap
    /// (see the constant's NatSpec for why this is belt-and-braces rather
    /// than a security boundary).
    /// @param pairId The pair whose payload carried the oversized window.
    /// @param timestamp The payload's observation timestamp.
    /// @param expiry The payload's rejected expiry.
    error ValidityWindowTooLong(bytes32 pairId, uint256 timestamp, uint256 expiry);
    /// @dev Raised when a signed update carries a zero `price`. A zero is the
    /// uninitialized default of the signing pipeline and, if served, values a
    /// pair at nothing downstream (e.g. Morpho collateral priced at zero).
    /// Rejected at the update boundary, symmetric with the other
    /// degenerate-value guards, per the fail-closed rule.
    /// @param pairId The pair whose update carried a zero price.
    error PriceZero(bytes32 pairId);
    error PriceUpdateInvalidSignature(bytes32 pairId);

    event SignerSet(address indexed signer);
    event PriceUpdated(bytes32 indexed pairId, uint256 price, uint256 timestamp, uint256 expiry);

    constructor() {
        _disableInitializers();
    }

    /// @notice Initialise the singleton. `admin` receives
    /// `DEFAULT_ADMIN_ROLE` (role administration only) and `oracleAdmin`
    /// receives `ORACLE_ADMIN_ROLE` (signer rotation) — both granted
    /// atomically so no post-deploy "remember to grant the role" step exists.
    /// A missing grant would leave `setSigner` uncallable, blocking an
    /// emergency key rotation behind the `DEFAULT_ADMIN` multisig while the
    /// compromised signer's permissionless payloads keep landing. The initial
    /// global signer is set here and announced through the same event the
    /// setter emits.
    /// @param admin Receives `DEFAULT_ADMIN_ROLE`. Cannot be zero.
    /// @param oracleAdmin Receives `ORACLE_ADMIN_ROLE`. Cannot be zero (may be
    /// the same address as `admin` if a single multisig holds both).
    /// @param signer_ The initial global publisher key. Cannot be zero.
    function initialize(address admin, address oracleAdmin, address signer_) external initializer {
        if (admin == address(0) || oracleAdmin == address(0)) revert ZeroAdmin();
        if (signer_ == address(0)) revert ZeroSigner();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_ADMIN_ROLE, oracleAdmin);

        _main().signer = signer_;
        emit SignerSet(signer_);
    }

    // ------------------------------------------------------------------ //
    //                        Global configuration                        //
    // ------------------------------------------------------------------ //

    /// @notice Rotate the GLOBAL publisher key. Rotation invalidates every
    /// outstanding payload signed by the old key, including any still-live
    /// validity windows.
    function setSigner(address newSigner) external onlyRole(ORACLE_ADMIN_ROLE) {
        if (newSigner == address(0)) revert ZeroSigner();
        _main().signer = newSigner;
        emit SignerSet(newSigner);
    }

    // ------------------------------------------------------------------ //
    //                            Price updates                           //
    // ------------------------------------------------------------------ //

    /// @notice The canonical pair id: base token first, quote token second,
    /// plain concatenation. Deterministic — no registration step exists;
    /// consumers and publishers derive the same id independently.
    function pairId(address baseToken, address quoteToken) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseToken, quoteToken));
    }

    /// @notice Push a signed price for a pair. Open — anyone may submit;
    /// the global publisher's EIP-712 signature over
    /// (pairId, price, timestamp, expiry) is what authorises. No
    /// registration is required: the first update on a brand-new pair works
    /// as-is.
    /// @return applied `true` if the update was strictly newer and was
    /// stored (a `PriceUpdated` event was emitted); `false` if the payload
    /// was not strictly newer than the stored timestamp — a deliberate
    /// NO-OP, so a lost update race can never revert a surrounding call. A
    /// strictly-newer payload timestamped in the FUTURE (`> block.timestamp`)
    /// reverts `PriceFuture`. A strictly-newer payload whose validity window
    /// has already CLOSED (`expiry <= block.timestamp`) reverts
    /// `PriceExpired` — an expired payload is permanently dead (see the
    /// contract NatSpec, "Producer-controlled validity"). A window longer than
    /// `MAX_VALIDITY_WINDOW` reverts `ValidityWindowTooLong`. A
    /// strictly-newer payload carrying a zero `price` reverts `PriceZero`.
    /// The signature is verified before the content checks, so an
    /// unauthenticated payload never reverts a content-check selector. A
    /// payload whose signature RECOVERS to a non-signer address reverts
    /// `PriceUpdateInvalidSignature`. A SYNTACTICALLY malformed signature
    /// (wrong length, `s` in the upper half-order, `v` not in {27,28})
    /// reverts inside `ECDSA.recover` FIRST, with OpenZeppelin's own
    /// `ECDSAInvalidSignatureLength` / `ECDSAInvalidSignatureS` /
    /// `ECDSAInvalidSignature` — so monitoring keyed on the revert selector
    /// must treat those three as equivalent to
    /// `PriceUpdateInvalidSignature`. Every path is fail-closed: no
    /// unsigned, malformed or expired payload is ever applied.
    function updatePrice(
        bytes32 id,
        uint256 newPrice,
        uint256 newTimestamp,
        uint256 newExpiry,
        bytes calldata signature
    ) external returns (bool applied) {
        MainStorage storage $ = _main();
        PricePoint storage stored = $.prices[id];

        // Not strictly newer → no-op, not a revert. Checked BEFORE the
        // signature so stale replays are cheap and never brick a caller.
        if (newTimestamp <= stored.timestamp) {
            return false;
        }

        // Verify the publisher signature BEFORE any content validation of the
        // payload, so an unauthenticated payload always reverts
        // `PriceUpdateInvalidSignature` — never a content-check selector
        // (`PriceFuture` / `PriceExpired` / `ValidityWindowTooLong` /
        // `PriceZero`) that would misreport an unsigned probe as an
        // operator/clock fault to off-chain monitoring. The stale/no-op
        // short-circuit above stays first: it is intentionally cheap and
        // signature-free so a lost update race can never brick a caller.
        bytes32 structHash = keccak256(abi.encode(PRICE_UPDATE_TYPEHASH, id, newPrice, newTimestamp, newExpiry));
        if (ECDSA.recover(MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash), signature) != $.signer) {
            revert PriceUpdateInvalidSignature(id);
        }

        // A future timestamp is out-of-model input: the payload claims an
        // observation instant that hasn't happened yet. Reject it — a
        // clock-skewed or buggy publisher signing `now + delta` is a
        // realistic operational fault, and admitting it would let the pair's
        // stored timestamp run ahead of wall-clock, blocking every honest
        // update signed in between. Miner drift on block.timestamp only
        // moves the accept/reject boundary by seconds and cannot forge a
        // signature, so the comparison is safe.
        // slither-disable-next-line timestamp
        if (newTimestamp > block.timestamp) {
            revert PriceFuture(id);
        }

        // A payload whose validity window has already closed is rejected
        // outright — the publisher has disowned this price, and being
        // strictly newer than the stored timestamp does not resurrect it.
        // The edge instant fails closed: at `block.timestamp == expiry` the
        // payload is expired. Same drift argument as above.
        // slither-disable-next-line timestamp
        if (newExpiry <= block.timestamp) {
            revert PriceExpired(id);
        }

        // Sanity-cap the window. The two checks above guarantee
        // `newTimestamp <= block.timestamp < newExpiry`, so the subtraction
        // cannot underflow and a coherent (positive-length) window is
        // already proven — only its SCALE is validated here.
        if (newExpiry - newTimestamp > MAX_VALIDITY_WINDOW) {
            revert ValidityWindowTooLong(id, newTimestamp, newExpiry);
        }

        // A zero price is the uninitialized default of the signing pipeline;
        // serving it would value the pair at nothing downstream. Reject it,
        // symmetric with the other degenerate-value guards.
        if (newPrice == 0) {
            revert PriceZero(id);
        }

        stored.price = newPrice;
        stored.timestamp = newTimestamp;
        stored.expiry = newExpiry;
        emit PriceUpdated(id, newPrice, newTimestamp, newExpiry);
        return true;
    }

    // ------------------------------------------------------------------ //
    //                            Read views                              //
    // ------------------------------------------------------------------ //

    /// @notice The stored price for a pair. Reverts `PriceUnset` when no
    /// update has ever landed (stored timestamp 0) and `PriceExpired` once
    /// `block.timestamp` reaches the stored payload's publisher-signed
    /// `expiry` (the edge instant fails closed — a price is dead AT its
    /// expiry). There is no other staleness bound: the producer's signed
    /// horizon is the staleness bound. Value semantics are the publisher's —
    /// this contract treats them as opaque.
    function price(bytes32 id) external view returns (uint256) {
        MainStorage storage $ = _main();
        PricePoint storage stored = $.prices[id];
        if (stored.timestamp == 0) revert PriceUnset(id);
        // Expiry is measured against block time by design — miner drift is
        // seconds against validity windows measured in minutes/hours.
        // slither-disable-next-line timestamp
        if (block.timestamp >= stored.expiry) revert PriceExpired(id);
        return stored.price;
    }

    /// @notice The global publisher key.
    function signer() external view returns (address) {
        return _main().signer;
    }

    /// @notice Raw stored price state (no expiry check) — for publishers
    /// sizing their next timestamp and for off-chain monitoring. Consumers
    /// of this RAW view that serve prices onward MUST apply the expiry
    /// themselves (`block.timestamp < storedExpiry`, fail closed), exactly
    /// as `price()` does.
    function pairPrice(bytes32 id)
        external
        view
        returns (uint256 storedPrice, uint256 storedTimestamp, uint256 storedExpiry)
    {
        PricePoint storage stored = _main().prices[id];
        return (stored.price, stored.timestamp, stored.expiry);
    }

    /// @notice EIP-712 domain separator — used by publishers / tests. A
    /// constant: the domain binds name + version only, so signed payloads
    /// replay across chains and deployments by design.
    function domainSeparator() external pure returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }
}
