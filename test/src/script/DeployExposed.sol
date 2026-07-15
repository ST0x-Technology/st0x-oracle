// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {Deploy} from "script/Deploy.sol";
import {DIAOracleUnifiedDeployer} from "src/concrete/deploy/DIAOracleUnifiedDeployer.sol";

/// @title DeployExposed
/// @dev Test-only subclass that exposes the internal `deployDIAStackInfra`
/// helper for unit testing. Calling `run()` directly is awkward because it
/// opens a `vm.startBroadcast`; this exposer lets the test drive the pure
/// wiring/postcondition logic without a broadcast or fork.
contract DeployExposed is Deploy {
    function exposedDeployDIAStackInfra(address beaconInitialOwner) external returns (DIAOracleUnifiedDeployer) {
        return deployDIAStackInfra(beaconInitialOwner);
    }
}
