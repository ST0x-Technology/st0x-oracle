// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test} from "forge-std-1.16.1/src/Test.sol";
import {DIA_FEED_BASE} from "../../../src/lib/LibDIAFeed.sol";

/// @title LibDIAFeedTest
/// @notice `DIA_FEED_BASE` is the single repo-level constant for the live DIA
/// push-oracle feed on Base. It is a deployment-address fact, not a derived
/// value, so the only thing a test can prove offline is that it has not
/// DRIFTED: no contract under `src/` reads it — per-vault oracles take their
/// feed from config — but the fork test and the README wiring example both
/// key off this literal, so a silent edit (a fat-fingered nibble, a
/// copy-paste from another chain's deployment) would steer every operator
/// copying the example to an address with no feed.
///
/// Before this test the constant was referenced only by the fork test, which
/// `vm.mockCall`s `getValue` AT that address — so the mock answers for any
/// address and the fork test passes unchanged against a wrong one. That left
/// the constant with zero coverage across the whole suite.
///
/// The expected value is re-derived from the primary source, not copied from
/// `LibDIAFeed.sol`: DIA's Base push oracle at
/// https://basescan.org/address/0xCE521b52513242c5094bc56f57887BB2A05B8129
/// (the same address the README wiring example and the `IDIAOracleV2` NatSpec
/// quote). Changing the deployment must therefore be a deliberate, reviewed
/// edit in two places rather than a one-character slip in one.
contract LibDIAFeedTest is Test {
    function testDIAFeedBaseAddressIsPinned() external pure {
        assertEq(
            DIA_FEED_BASE,
            address(0xCE521b52513242c5094bc56f57887BB2A05B8129),
            "DIA_FEED_BASE must be the DIA push-oracle deployment on Base"
        );
    }

    /// The constant must be a real address, not a zero/placeholder left behind
    /// by a template. A zero feed would make every DIA read return empty
    /// calldata results and fail in a confusing place far from the config.
    function testDIAFeedBaseIsNotZero() external pure {
        assertTrue(DIA_FEED_BASE != address(0), "DIA_FEED_BASE must not be the zero address");
    }
}
