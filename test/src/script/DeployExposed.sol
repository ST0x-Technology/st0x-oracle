// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Deploy} from "../../../script/Deploy.sol";
import {DIAVaultOracleBeaconSetDeployer} from "../../../src/concrete/deploy/DIAVaultOracleBeaconSetDeployer.sol";

/// @title DeployExposed
/// @dev Test-only subclass that exposes the internal deploy helpers for unit
/// testing. Calling `run()` directly is awkward because it opens a
/// `vm.startBroadcast`; this exposer lets the test drive the pure
/// wiring/postcondition logic without a broadcast or fork.
contract DeployExposed is Deploy {
    function exposedDeployDIAStackInfra(address beaconInitialOwner) external returns (DIAVaultOracleBeaconSetDeployer) {
        return deployDIAStackInfra(beaconInitialOwner);
    }

    function exposedDeploySignedPriceStack(address beaconInitialOwner, address deployer) external {
        deploySignedPriceStack(beaconInitialOwner, deployer);
    }
}
