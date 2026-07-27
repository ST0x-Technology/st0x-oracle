// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

/// @title DeployRecordBase
/// @notice Committed, per-release deployment record for the DIA oracle stack on
/// Base (chainId 8453) — the durable, in-repo freeze the audit (#259) asks for.
///
/// The deploy script (`script/Deploy.sol`) mints the beacon-set deployer, the
/// implementation and the per-vault proxies. Their addresses are
/// CREATE/nonce-dependent (or, for proxies, CREATE2-salted off a runtime beacon
/// address), so they are NOT reproducible from committed source alone. Without a
/// record, the only trace of a deploy is the CI workflow log, which expires —
/// leaving nobody able to confirm the live infra is the code this repo built,
/// and letting a re-deploy silently fork a divergent second set.
///
/// This library freezes, per deployed contract, its address AND the runtime
/// codehash (`keccak256(address.code)`) observed on-chain. The check
/// (see `DeployRecordLibBase.verifyCodehash`) asserts the live code at each
/// recorded address still hashes to the recorded value — i.e. the live infra is
/// byte-identical to what was frozen at record time and nobody has swapped it.
///
/// @dev RELEASE PROVENANCE — READ BEFORE PINNING TO CURRENT SOURCE.
/// The recorded DIA stack below is the FIRST Base release ("pre-fold"). It was
/// recovered from the deploy broadcast (the record's whole point: it outlives
/// the CI logs it was parsed from) and re-read on-chain via a Base archive fork
/// to capture the live codehashes verbatim. That release predates the
/// architecture change that FOLDED the corporate-action pause wrapper INTO
/// `DIAVaultOracle` and deleted the separate `PausableOracleWrapper` (commit
/// e0a355e), plus the ERC-7201 storage + hardening sweep. So the recorded
/// implementation/deployer codehashes DO NOT equal the artifacts the current
/// source tree builds, and they are NOT supposed to — this is a record of the
/// LIVE release, not of `forge build` HEAD. The codehash check is a
/// "has the live code changed since we froze it" guard, not a "does the live
/// code match current source" guard. When the stack is redeployed onto the
/// current (folded, ERC-7201) implementations, ADD a new record block for that
/// release rather than mutating these values.
///
/// The signed-price stack (`ST0xPriceOracle` + its beacon-set deployer + the
/// `MorphoPairAdapterBeaconSetDeployer`) is NOT yet deployed on Base; its record
/// is intentionally EMPTY (address(0) / bytes32(0)) — populate at first deploy.
library DeployRecordBase {
    /// @notice The chain this record pins.
    uint256 internal constant CHAIN_ID = 8453;

    // -------------------------------------------------------------------------
    // DIA stack — FIRST ("pre-fold") Base release. Addresses recovered from the
    // deploy broadcast; codehashes re-read on-chain (Base) at record time.
    // These are the SUPERSEDED-architecture impls (separate wrapper); see the
    // library-level PROVENANCE note. The check verifies the live code has not
    // changed since it was frozen, NOT that it matches current source.
    // -------------------------------------------------------------------------

    /// @notice `DIAVaultOracleBeaconSetDeployer` — owns the upgradeable beacon
    /// and mints DIA oracle proxies. Non-deterministic (plain `new`) address.
    address internal constant DIA_VAULT_ORACLE_BEACON_SET_DEPLOYER = 0x8B8cc6db58E5bb9F507FFce893246958c7Ca9F6d;
    bytes32 internal constant DIA_VAULT_ORACLE_BEACON_SET_DEPLOYER_CODEHASH =
        0x2ac9292ab325265fada5a4c160b6cfe480eb78236698bc8e31e1189f441b1217;

    /// @notice `DIAVaultOracle` implementation behind the beacon.
    address internal constant DIA_VAULT_ORACLE_IMPLEMENTATION = 0x2e5ddDFbe97f1421e4ccEf0c423374379502a132;
    bytes32 internal constant DIA_VAULT_ORACLE_IMPLEMENTATION_CODEHASH =
        0x5b660e31453047e65e5114dcf09480d7ea41272f4203c3d25225824e641a8f52;

    /// @notice The one live DIA oracle proxy (wtCOIN). CREATE2-salted off the
    /// beacon address + `keccak256(abi.encode(config))`.
    address internal constant DIA_WTCOIN_ORACLE_PROXY = 0xef31D3E7c6a60e0725758Cd318603c7864b3278A;
    bytes32 internal constant DIA_WTCOIN_ORACLE_PROXY_CODEHASH =
        0x576541507f08b924e100efe6730152cead62ad86776e05e207d32699bc79f510;

    // -------------------------------------------------------------------------
    // Signed-price stack — NOT deployed on Base. EMPTY: populate at first deploy.
    // -------------------------------------------------------------------------

    address internal constant ST0X_PRICE_ORACLE_BEACON_SET_DEPLOYER = address(0);
    bytes32 internal constant ST0X_PRICE_ORACLE_BEACON_SET_DEPLOYER_CODEHASH = bytes32(0);

    address internal constant ST0X_PRICE_ORACLE_IMPLEMENTATION = address(0);
    bytes32 internal constant ST0X_PRICE_ORACLE_IMPLEMENTATION_CODEHASH = bytes32(0);

    address internal constant ST0X_PRICE_ORACLE_SINGLETON_PROXY = address(0);
    bytes32 internal constant ST0X_PRICE_ORACLE_SINGLETON_PROXY_CODEHASH = bytes32(0);

    address internal constant MORPHO_PAIR_ADAPTER_BEACON_SET_DEPLOYER = address(0);
    bytes32 internal constant MORPHO_PAIR_ADAPTER_BEACON_SET_DEPLOYER_CODEHASH = bytes32(0);
}
