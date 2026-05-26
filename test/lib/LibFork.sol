// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity ^0.8.25;

import {Vm} from "forge-std-1.16.1/src/StdCheats.sol";

uint256 constant FORK_BLOCK_BASE = 38996123;

library LibFork {
    function createSelectForkBase(Vm vm) internal {
        vm.createSelectFork(vm.envString("RPC_URL_BASE_FORK"), FORK_BLOCK_BASE);
    }
}
