// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {IPyth} from "pyth-sdk/IPyth.sol";
import {PythStructs} from "pyth-sdk/PythStructs.sol";
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {
    BasePythOracleAdapter,
    CorporateActionPauseConfig,
    ZeroVault,
    ZeroAdmin
} from "src/abstract/BasePythOracleAdapter.sol";

/// @dev Error raised when a zero price ID is provided.
error ZeroPriceId();

/// @dev Error raised when a zero max age is provided.
error ZeroMaxAge();

/// @title PythOracleAdapterConfig
/// @notice Configuration for PythOracleAdapter initialization.
/// @param vault The ERC-4626 vault address this oracle prices shares for.
/// @param priceId The Pyth price feed ID for the underlying asset.
/// @param maxAge Maximum acceptable price age in seconds.
/// @param admin The admin address for governance.
/// @param pauseConfig Corporate-action auto-pause config — see SPEC § 16.
/// All-zero is the legacy/manual-only mode; `corporateActionsVault =
/// address(0)` disables auto-pause for the life of the proxy.
struct PythOracleAdapterConfig {
    address vault;
    bytes32 priceId;
    uint256 maxAge;
    address admin;
    CorporateActionPauseConfig pauseConfig;
}

/// @title PythOracleAdapter
/// @notice Oracle adapter that prices ERC-4626 vault shares by fetching the
/// underlying asset price from Pyth Network and multiplying by the vault's
/// assets-per-share ratio. Exposes prices via Chainlink's
/// AggregatorV2V3Interface. This is the canonical oracle per vault.
/// Configuration (priceId, maxAge, pauseConfig) is set once at initialization
/// and is immutable thereafter — deploy a new proxy to change config and
/// update protocol adapters via setOracle. Only governance is pause/unpause.
/// Pyth contract address is NOT stored - derived at runtime from
/// LibPyth.getPriceFeedContract(block.chainid).
/// Uses conservative pricing (price - confidence interval) per rain.pyth
/// patterns. Scaling uses LibDecimalFloat for audited precision.
///
/// Price formula: vaultSharePrice = (pythPrice - pythConfidence) * totalAssets / totalSupply
/// — i.e. the conservative price is used. See SPEC §15.2 and
/// `BasePythOracleAdapter._conservativePriceFloat`.
contract PythOracleAdapter is BasePythOracleAdapter, ICloneableV2, Initializable {
    /// @dev The Pyth price feed ID for the underlying asset.
    bytes32 public priceId;
    /// @dev Maximum acceptable price age in seconds.
    uint256 public maxAge;

    /// @notice Emitted when the oracle is initialized.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event PythOracleAdapterInitialized(address indexed sender, PythOracleAdapterConfig config);

    constructor() {
        _disableInitializers();
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// ICloneableV2 this overload MUST always revert; callers should use the
    /// `bytes calldata` overload instead.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
    function initialize(PythOracleAdapterConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        PythOracleAdapterConfig memory config = abi.decode(data, (PythOracleAdapterConfig));

        if (config.vault == address(0)) revert ZeroVault();
        if (config.priceId == bytes32(0)) revert ZeroPriceId();
        if (config.maxAge == 0) revert ZeroMaxAge();
        if (config.admin == address(0)) revert ZeroAdmin();

        vault = config.vault;
        priceId = config.priceId;
        maxAge = config.maxAge;
        admin = config.admin;
        _setCorporateActionPauseConfig(config.pauseConfig);

        emit PythOracleAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    /// @inheritdoc BasePythOracleAdapter
    // slither-disable-next-line pyth-unchecked-confidence
    function _getPriceData() internal view override returns (PythStructs.Price memory) {
        IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
        return pyth.getPriceNoOlderThan(priceId, maxAge);
    }
}
