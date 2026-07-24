// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ERC1967Proxy} from "@openzeppelin-contracts-5.6.1/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev OZ v5's `ERC1967Proxy` reverts in its constructor when `_data` is
/// empty. Override `_unsafeAllowUninitialized` so the test harness can stand
/// the proxy up first and call `initialize(bytes)` explicitly — that lets
/// every init test go through the same path (`proxy.initialize(...)`) and
/// keeps return-value assertions on the success hash straightforward.
contract TestERC1967Proxy is ERC1967Proxy {
    constructor(address impl) ERC1967Proxy(impl, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}
