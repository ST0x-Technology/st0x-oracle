// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
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
                initialOwner: address(this),
                initialPythOracleAdapterImplementation: address(I_IMPLEMENTATION)
            })
        );
    }

    function createOracle(address vault, bytes32 priceId, uint256 maxAge, address admin)
        internal
        returns (PythOracleAdapter)
    {
        return I_DEPLOYER.newPythOracleAdapter(
            PythOracleAdapterConfig({vault: vault, priceId: priceId, maxAge: maxAge, admin: admin})
        );
    }
}
