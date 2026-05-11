// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {
    BasePythOracleAdapter,
    CorporateActionPauseConfig,
    CorporateActionConfigAlreadyInitialized
} from "st0x.oracle/abstract/BasePythOracleAdapter.sol";

/// @dev Minimal harness exposing `_setCorporateActionPauseConfig` for direct
/// invocation. The base adapter's helper is `internal`; we override the
/// abstract `_getPriceData` with a no-op since no price reads happen here.
contract CorporateActionConfigHarness is BasePythOracleAdapter {
    function setConfig(CorporateActionPauseConfig memory config) external {
        _setCorporateActionPauseConfig(config);
    }

    function _getPriceData() internal pure override returns (PythStructs.Price memory p) {
        return p;
    }
}

/// @title BasePythOracleAdapterCorporateActionConfigTest
/// @notice Tests the SPEC §16.2 immutable-after-initialize invariant on the
/// four corporate-action pause storage slots, plus the new install-time event.
/// Closes audits #148 and #149.
contract BasePythOracleAdapterCorporateActionConfigTest is Test {
    function _cfg(address vault) internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: vault, actionTypeMask: 0x1, pauseTimeBefore: 60, pauseTimeAfter: 120
        });
    }

    /// First call to `_setCorporateActionPauseConfig` populates the four
    /// governance slots; a second call reverts with
    /// `CorporateActionConfigAlreadyInitialized`. The internal `bool` flag
    /// codifies the invariant rather than relying on subclass discipline.
    /// Closes audit #148.
    function testCorporateActionConfigImmutableAfterInitialize(address vault) external {
        CorporateActionConfigHarness h = new CorporateActionConfigHarness();
        h.setConfig(_cfg(vault));

        assertEq(h.corporateActionsVault(), vault);
        assertEq(h.actionTypeMask(), 0x1);
        assertEq(h.pauseTimeBefore(), 60);
        assertEq(h.pauseTimeAfter(), 120);

        vm.expectRevert(CorporateActionConfigAlreadyInitialized.selector);
        h.setConfig(_cfg(address(0)));
    }

    /// `CorporateActionConfigAlreadyInitialized` selector also fires when the
    /// second call's payload happens to be identical to the first — the guard
    /// is positional, not content-aware. Closes audit #148.
    function testCorporateActionConfigRevertsOnIdenticalReinit(address vault) external {
        CorporateActionConfigHarness h = new CorporateActionConfigHarness();
        h.setConfig(_cfg(vault));
        vm.expectRevert(CorporateActionConfigAlreadyInitialized.selector);
        h.setConfig(_cfg(vault));
    }

    /// `_setCorporateActionPauseConfig` must emit
    /// `CorporateActionPauseConfigSet` with every installed field so off-chain
    /// indexers can reconstruct the four governance slots from logs alone.
    /// Closes audit #149.
    function testCorporateActionConfigEmitsInstallEvent(address vault, uint256 mask, uint64 before_, uint64 after_)
        external
    {
        CorporateActionConfigHarness h = new CorporateActionConfigHarness();
        CorporateActionPauseConfig memory cfg = CorporateActionPauseConfig({
            corporateActionsVault: vault, actionTypeMask: mask, pauseTimeBefore: before_, pauseTimeAfter: after_
        });

        vm.expectEmit();
        emit BasePythOracleAdapter.CorporateActionPauseConfigSet(vault, mask, before_, after_);
        h.setConfig(cfg);
    }
}
