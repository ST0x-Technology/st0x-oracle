// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {BeaconProxy} from "@openzeppelin-contracts-5.6.1/proxy/beacon/BeaconProxy.sol";

/// @dev Raised when the live runtime code at a recorded address does not hash to
/// the recorded codehash — i.e. the live infra has diverged from the frozen
/// release (swapped, self-destructed, or never deployed there).
/// @param account The recorded address whose live code was checked.
/// @param expected The codehash frozen in the deployment record.
/// @param actual The codehash of the code currently at `account`.
error DeployRecordCodehashMismatch(address account, bytes32 expected, bytes32 actual);

/// @dev Raised when a CREATE2 proxy's actual address does not equal the address
/// deterministically derived from its deployer, beacon and config salt — i.e.
/// the proxy is NOT the deterministic commitment to that config.
/// @param expected The CREATE2-derived address.
/// @param actual The address the proxy actually deployed at.
error DeployRecordAddressMismatch(address expected, address actual);

/// @title DeployRecordLib
/// @notice The check that makes a `DeployRecordBase`-style freeze verifiable:
/// pure/`view` helpers asserting (a) the live runtime codehash at a recorded
/// address equals the recorded codehash and (b) a CREATE2 beacon-proxy landed at
/// its deterministically-derived address. Kept free of any specific record so
/// both the local self-test and the live fork test drive the SAME logic.
library DeployRecordLib {
    /// @notice Assert the code currently at `account` hashes to `expected`.
    /// Reverts `DeployRecordCodehashMismatch` on any divergence (including the
    /// no-code case, whose codehash is `keccak256("")`, distinct from a real
    /// recorded hash). `bytes32(0)` (unset record slot) is treated as
    /// "nothing to check" and skipped so an empty record no-ops rather than
    /// asserting against `address(0)`.
    /// @param account The recorded address to verify.
    /// @param expected The recorded codehash.
    function verifyCodehash(address account, bytes32 expected) internal view {
        if (expected == bytes32(0)) {
            return;
        }
        bytes32 actual = account.codehash;
        if (actual != expected) {
            revert DeployRecordCodehashMismatch(account, expected, actual);
        }
    }

    /// @notice The CREATE2 address a `DIA*BeaconSetDeployer`-style contract mints
    /// a `BeaconProxy(beacon, "")` to, for a given salt. Empty init-data means
    /// the salt is the sole source of address uniqueness — this mirrors the
    /// exact derivation the deployer performs.
    /// @param deployer The contract executing the CREATE2 (the beacon-set deployer).
    /// @param beacon The beacon address baked into the proxy constructor args.
    /// @param salt The CREATE2 salt (`keccak256(abi.encode(config))`).
    /// @return The deterministically-derived proxy address.
    function deriveBeaconProxyAddress(address deployer, address beacon, bytes32 salt) internal pure returns (address) {
        // `type(BeaconProxy).creationCode` inlines the proxy bytecode; slither's
        // too-many-digits detector flags the embedded literal. This is the
        // canonical CREATE2 init-code-hash derivation, not a magic number.
        // slither-disable-start too-many-digits
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, bytes(""))));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
        // slither-disable-end too-many-digits
    }

    /// @notice Assert a beacon proxy landed at its deterministically-derived
    /// address. Reverts `DeployRecordAddressMismatch` otherwise.
    /// @param actual The proxy's actual address.
    /// @param deployer The beacon-set deployer that minted it.
    /// @param beacon The beacon baked into the proxy.
    /// @param salt The CREATE2 salt used.
    function verifyBeaconProxyAddress(address actual, address deployer, address beacon, bytes32 salt) internal pure {
        address expected = deriveBeaconProxyAddress(deployer, beacon, salt);
        if (actual != expected) {
            revert DeployRecordAddressMismatch(expected, actual);
        }
    }
}
