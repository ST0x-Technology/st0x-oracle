// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std-1.16.1/src/Test.sol";
import {CorporateActionPauseConfig} from "src/abstract/BasePythOracleAdapter.sol";
import {PythOracleAdapter, PythOracleAdapterConfig} from "src/concrete/oracle/PythOracleAdapter.sol";
import {
    PythOracleAdapterBeaconSetDeployer,
    PythOracleAdapterBeaconSetDeployerConfig
} from "src/concrete/deploy/PythOracleAdapterBeaconSetDeployer.sol";

contract PythOracleAdapterTest is Test {
    PythOracleAdapter internal immutable I_IMPLEMENTATION;
    PythOracleAdapterBeaconSetDeployer internal immutable I_DEPLOYER;

    constructor() {
        I_IMPLEMENTATION = new PythOracleAdapter();
        I_DEPLOYER = new PythOracleAdapterBeaconSetDeployer(
            PythOracleAdapterBeaconSetDeployerConfig({
                initialOwner: address(this), initialPythOracleAdapterImplementation: address(I_IMPLEMENTATION)
            })
        );
    }

    /// @dev Default helper used by tests that don't care about auto-pause —
    /// emits an empty `CorporateActionPauseConfig` so the adapter is in
    /// manual-only mode.
    function createOracle(address vault, bytes32 priceId, uint256 maxAge, address admin)
        internal
        returns (PythOracleAdapter)
    {
        return I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: vault, priceId: priceId, maxAge: maxAge, admin: admin, pauseConfig: _emptyPauseConfig()
            })
        );
    }

    /// @dev Helper for tests exercising the corporate-action auto-pause.
    function createOracleWithPause(
        address vault,
        bytes32 priceId,
        uint256 maxAge,
        address admin,
        CorporateActionPauseConfig memory pauseConfig
    ) internal returns (PythOracleAdapter) {
        return I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({
                vault: vault, priceId: priceId, maxAge: maxAge, admin: admin, pauseConfig: pauseConfig
            })
        );
    }

    function _emptyPauseConfig() internal pure returns (CorporateActionPauseConfig memory) {
        return CorporateActionPauseConfig({
            corporateActionsVault: address(0), actionTypeMask: 0, pauseTimeBefore: 0, pauseTimeAfter: 0
        });
    }
}
