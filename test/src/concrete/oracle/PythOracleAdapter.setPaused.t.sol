// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {PythOracleAdapterTest} from "test/abstract/PythOracleAdapterTest.sol";
import {OraclePausedManual, OnlyAdmin, ZeroAdmin, BasePythOracleAdapter} from "src/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter} from "src/concrete/oracle/PythOracleAdapter.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";

contract PythOracleAdapterSetPausedTest is PythOracleAdapterTest {
    /// Test that setPaused works for admin.
    function testSetPaused(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        assertEq(oracle.paused(), false);

        vm.prank(admin);
        oracle.setPaused(true);
        assertEq(oracle.paused(), true);

        vm.prank(admin);
        oracle.setPaused(false);
        assertEq(oracle.paused(), false);
    }

    /// Test that setPaused reverts for non-admin.
    function testSetPausedOnlyAdmin(address vault, bytes32 priceId, uint256 maxAge, address admin, address nonAdmin)
        external
    {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.assume(nonAdmin != admin);

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        oracle.setPaused(true);
    }

    /// Test that latestAnswer reverts when paused.
    function testLatestAnswerWhenPaused(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(admin);
        oracle.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        oracle.latestAnswer();
    }

    /// Test that latestRoundData reverts when paused.
    function testLatestRoundDataWhenPaused(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(admin);
        oracle.setPaused(true);

        vm.expectRevert(abi.encodeWithSelector(OraclePausedManual.selector));
        oracle.latestRoundData();
    }

    /// Test that PauseSet event is emitted.
    function testPauseSetEvent(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.expectEmit();
        emit BasePythOracleAdapter.PauseSet(true);
        vm.prank(admin);
        oracle.setPaused(true);

        vm.expectEmit();
        emit BasePythOracleAdapter.PauseSet(false);
        vm.prank(admin);
        oracle.setPaused(false);
    }

    /// `BasePythOracleAdapter.setAdmin` must emit `AdminSet(old, new)` and
    /// rotate the admin so the old admin loses access and the new one gains it.
    /// Closes audit #50.
    function testSetAdminEmitsEventAndRotates(
        address vault,
        bytes32 priceId,
        uint256 maxAge,
        address admin,
        address newAdmin
    ) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.assume(newAdmin != address(0));
        vm.assume(admin != newAdmin);

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.expectEmit(true, true, true, true);
        emit BasePythOracleAdapter.AdminSet(admin, newAdmin);
        vm.prank(admin);
        oracle.setAdmin(newAdmin);

        assertEq(oracle.admin(), newAdmin);

        // Old admin can no longer act.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        oracle.setPaused(true);

        // New admin can.
        vm.prank(newAdmin);
        oracle.setPaused(true);
        assertTrue(oracle.paused());
    }

    /// `setAdmin(address(0))` must revert with `ZeroAdmin` even from the
    /// current admin. Closes audit #50.
    function testSetAdminRevertsZeroAddress(address vault, bytes32 priceId, uint256 maxAge, address admin) external {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ZeroAdmin.selector));
        oracle.setAdmin(address(0));
    }

    /// Non-admin caller of `setAdmin` must revert with `OnlyAdmin`. Closes
    /// audit #50.
    function testSetAdminOnlyAdmin(address vault, bytes32 priceId, uint256 maxAge, address admin, address nonAdmin)
        external
    {
        vm.assume(vault != address(0));
        vm.assume(priceId != bytes32(0));
        vm.assume(maxAge > 0);
        vm.assume(admin != address(0));
        vm.assume(nonAdmin != admin);

        PythOracleAdapter oracle = createOracle(vault, priceId, maxAge, admin);

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(OnlyAdmin.selector));
        oracle.setAdmin(address(1));
    }
}
