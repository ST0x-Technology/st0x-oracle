// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std/Test.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";
import {
    MultiPythOracleAdapter,
    MultiPythOracleAdapterConfig,
    FeedConfig,
    ZeroPriceId,
    ZeroMaxAge,
    ZeroFeeds,
    TooManyFeeds,
    MAX_FEEDS
} from "src/concrete/oracle/MultiPythOracleAdapter.sol";
import {
    MultiPythOracleAdapterBeaconSetDeployer,
    MultiPythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/MultiPythOracleAdapterBeaconSetDeployer.sol";

bytes32 constant FEED_A = bytes32(uint256(0x1111));
bytes32 constant FEED_B = bytes32(uint256(0x2222));
bytes32 constant FEED_C = bytes32(uint256(0x3333));

/// @title MultiPythOracleAdapterSetFeedsOrderingTest
/// @notice Locks in the validate-before-mutate ordering of `_setFeeds` and
/// the helper-internalised `MAX_FEEDS` / `ZeroFeeds` checks introduced by
/// audit #41 / #179 / #180. No fork required; we never read a price here.
contract MultiPythOracleAdapterSetFeedsOrderingTest is Test {
    MultiPythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        MultiPythOracleAdapter implementation = new MultiPythOracleAdapter();
        I_DEPLOYER = new MultiPythOracleAdapterBeaconSetDeployer(
            MultiPythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialMultiPythOracleAdapterImplementation: address(implementation)
            })
        );
    }

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }

    function _initial(uint256 n) internal pure returns (FeedConfig[] memory feeds) {
        feeds = new FeedConfig[](n);
        if (n >= 1) feeds[0] = FeedConfig({priceId: FEED_A, maxAge: 300});
        if (n >= 2) feeds[1] = FeedConfig({priceId: FEED_B, maxAge: 600});
        if (n >= 3) feeds[2] = FeedConfig({priceId: FEED_C, maxAge: 900});
    }

    function _deployWith(uint256 n) internal returns (MultiPythOracleAdapter) {
        address mockVault = address(uint160(uint256(keccak256(abi.encode("vault.setfeeds.ordering", n)))));
        return I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: _initial(n), admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// Validate-before-mutate: a `setFeeds` call that fails per-element
    /// validation (here, index 1 has a zero priceId) MUST leave the existing
    /// feed list unchanged. Pre-fix, `_setFeeds` mutated `feedCount` and
    /// cleared tail slots before validating, so a revert would still roll back
    /// only by virtue of Solidity's outer revert. Post-fix, validation runs
    /// first so the storage is provably untouched at the source level.
    /// Closes audit #41 / #179.
    function testSetFeedsValidatesBeforeMutating() external {
        MultiPythOracleAdapter adapter = _deployWith(3);

        FeedConfig[] memory bad = new FeedConfig[](3);
        bad[0] = FeedConfig({priceId: FEED_C, maxAge: 100});
        bad[1] = FeedConfig({priceId: bytes32(0), maxAge: 100});
        bad[2] = FeedConfig({priceId: FEED_A, maxAge: 100});

        vm.expectRevert(abi.encodeWithSelector(ZeroPriceId.selector, uint256(1)));
        adapter.setFeeds(bad);

        // Original 3 feeds must still be intact.
        assertEq(adapter.feedCount(), 3);
        FeedConfig memory f0 = adapter.getFeed(0);
        assertEq(f0.priceId, FEED_A);
        assertEq(f0.maxAge, 300);
        FeedConfig memory f1 = adapter.getFeed(1);
        assertEq(f1.priceId, FEED_B);
        assertEq(f1.maxAge, 600);
        FeedConfig memory f2 = adapter.getFeed(2);
        assertEq(f2.priceId, FEED_C);
        assertEq(f2.maxAge, 900);
    }

    /// `_setFeeds` now self-guards `MAX_FEEDS` / non-empty, so `initialize`
    /// with too many feeds reverts via the same helper rather than a
    /// duplicated check on the caller. Closes audit #180.
    function testInitializeTooManyFeedsRevertsViaHelper() external {
        FeedConfig[] memory feeds = new FeedConfig[](MAX_FEEDS + 1);
        for (uint256 i = 0; i < feeds.length; i++) {
            feeds[i] = FeedConfig({priceId: bytes32(uint256(i + 1)), maxAge: 300});
        }
        address mockVault = address(uint160(uint256(keccak256("vault.helper.toomany"))));
        vm.expectRevert(abi.encodeWithSelector(TooManyFeeds.selector));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// `_setFeeds` now self-guards non-empty, so `initialize` with zero feeds
    /// reverts via the same helper rather than a duplicated check on the
    /// caller. Closes audit #180.
    function testInitializeZeroFeedsRevertsViaHelper() external {
        FeedConfig[] memory feeds = new FeedConfig[](0);
        address mockVault = address(uint160(uint256(keccak256("vault.helper.zero"))));
        vm.expectRevert(abi.encodeWithSelector(ZeroFeeds.selector));
        I_DEPLOYER.newMultiPythOracleAdapter(
            MultiPythOracleAdapterConfig({
                vault: mockVault, feeds: feeds, admin: address(this), pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// `setFeeds` empty-list still reverts even after dedup of the public-side
    /// fast-path check, because the helper now self-guards. Closes audit
    /// #180.
    function testSetFeedsZeroFeedsRevertsViaHelper() external {
        MultiPythOracleAdapter adapter = _deployWith(2);
        FeedConfig[] memory empty = new FeedConfig[](0);
        vm.expectRevert(abi.encodeWithSelector(ZeroFeeds.selector));
        adapter.setFeeds(empty);
    }

    /// Symmetric: `setFeeds` too-many still reverts even after dedup of the
    /// public-side fast-path check. Closes audit #180.
    function testSetFeedsTooManyFeedsRevertsViaHelper() external {
        MultiPythOracleAdapter adapter = _deployWith(2);
        FeedConfig[] memory feeds = new FeedConfig[](MAX_FEEDS + 1);
        for (uint256 i = 0; i < feeds.length; i++) {
            feeds[i] = FeedConfig({priceId: bytes32(uint256(i + 1)), maxAge: 300});
        }
        vm.expectRevert(abi.encodeWithSelector(TooManyFeeds.selector));
        adapter.setFeeds(feeds);
    }

    /// Bare ZeroMaxAge at index 1 inside a setFeeds call must surface the
    /// indexed error AND leave the prior feed list intact. Locks in the
    /// post-fix ordering once more for the ZeroMaxAge selector. Closes
    /// audit #41.
    function testSetFeedsValidatesBeforeMutatingZeroMaxAge() external {
        MultiPythOracleAdapter adapter = _deployWith(2);

        FeedConfig[] memory bad = new FeedConfig[](2);
        bad[0] = FeedConfig({priceId: FEED_C, maxAge: 100});
        bad[1] = FeedConfig({priceId: FEED_A, maxAge: 0});

        vm.expectRevert(abi.encodeWithSelector(ZeroMaxAge.selector, uint256(1)));
        adapter.setFeeds(bad);

        // Original 2 feeds must still be intact.
        assertEq(adapter.feedCount(), 2);
        assertEq(adapter.getFeed(0).priceId, FEED_A);
        assertEq(adapter.getFeed(0).maxAge, 300);
        assertEq(adapter.getFeed(1).priceId, FEED_B);
        assertEq(adapter.getFeed(1).maxAge, 600);
    }
}
