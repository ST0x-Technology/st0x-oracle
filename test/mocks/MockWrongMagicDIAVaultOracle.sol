// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

/// @title MockWrongMagicDIAVaultOracle
/// @notice A stand-in `DIAVaultOracle` implementation whose `initialize(bytes)`
/// succeeds (does NOT revert) but returns the WRONG magic value — anything
/// other than `ICLONEABLE_V2_SUCCESS`. Used to prove
/// `DIAVaultOracleBeaconSetDeployer.newDIAVaultOracle` rejects a wrong-magic
/// return with `InitializeOracleFailed`, as opposed to a reverting init (which
/// the deployer merely propagates). Placed behind a beacon so the deployer's
/// `BeaconProxy` delegatecalls into it.
contract MockWrongMagicDIAVaultOracle {
    /// @dev Returns a sentinel that is deliberately NOT `ICLONEABLE_V2_SUCCESS`.
    function initialize(bytes calldata) external pure returns (bytes32) {
        return bytes32(uint256(0xdead));
    }
}
