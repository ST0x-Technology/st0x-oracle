// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {CorporateActionPauseConfig} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig
} from "st0x.oracle/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "st0x.oracle/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";

/// @title MultiPythOracleAdapterStorageLayoutTest
/// @notice Pins the on-chain storage slot positions of
/// `BasePythOracleAdapter.vault` and `MultiPythOracleAdapter.feedCount` so an
/// accidental reordering of base-class state (e.g. forgetting to decrement
/// `__gap`) is caught by CI rather than silently shifting subclass slots.
///
/// The slot for `feedCount` is the first slot AFTER the
/// `BasePythOracleAdapter`'s 50-slot `__gap`. Adding new base-class state
/// requires decrementing the `__gap` length by an equivalent number of slots
/// so this assertion keeps holding without rewriting it.
///
/// No fork is required — initialization writes to storage on the in-memory
/// EVM, and `vm.load` reads it back. The Pyth integration is not exercised.
contract MultiPythOracleAdapterStorageLayoutTest is Test {
    /// @dev Slot 0 of the proxy storage: `BasePythOracleAdapter.vault`.
    uint256 internal constant VAULT_SLOT = 0;

    /// @dev Post-`__gap` slot in `MultiPythOracleAdapter`: `feedCount`.
    /// Derivation: 5 base-class slots (mutable governance + corporate-action
    /// config) + 50 reserved gap slots = 55.
    uint256 internal constant FEED_COUNT_SLOT = 55;

    MultiPythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    bytes32 constant FEED_A = 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245;

    constructor() {
        MultiPythOracleAdapter implementation = new MultiPythOracleAdapter();
        I_DEPLOYER = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMultiPythOracleAdapterImplementation: address(implementation)
            })
        );
    }

    /// @notice Initialize a proxy with a known vault and one feed; then read
    /// slot 0 and the post-gap slot raw via `vm.load` and assert both match
    /// the values written by `initialize`.
    function testStorageLayoutPinned(address vault, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(admin != address(0));

        FeedConfig[] memory feeds = new FeedConfig[](1);
        feeds[0] = FeedConfig({priceId: FEED_A, maxAge: 300});

        CorporateActionPauseConfig memory pauseConfig = CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });

        MultiPythOracleAdapter adapter = I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({vault: vault, feeds: feeds, admin: admin, pauseConfig: pauseConfig})
        );

        bytes32 vaultSlotValue = vm.load(address(adapter), bytes32(VAULT_SLOT));
        assertEq(address(uint160(uint256(vaultSlotValue))), vault, "slot 0 must hold BasePythOracleAdapter.vault");

        bytes32 feedCountSlotValue = vm.load(address(adapter), bytes32(FEED_COUNT_SLOT));
        assertEq(uint256(feedCountSlotValue), 1, "post-gap slot must hold MultiPythOracleAdapter.feedCount");
    }
}
