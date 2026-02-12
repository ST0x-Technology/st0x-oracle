// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AggregatorV3Interface} from "src/interface/IAggregatorV3.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when a zero address is provided for the registry.
error ZeroRegistry();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when no oracle is found for the vault in the registry.
error OracleNotFound();

/// @title PassthroughProtocolAdapterConfig
/// @notice Configuration for PassthroughProtocolAdapter initialization.
/// @param registry The oracle registry address.
/// @param vault The vault address this adapter serves.
/// @param admin The admin address.
struct PassthroughProtocolAdapterConfig {
    OracleRegistry registry;
    address vault;
    address admin;
}

/// @title PassthroughProtocolAdapter
/// @notice Protocol adapter for Aave V3, Compound V3, and any future
/// Chainlink-compatible protocol. Passes through all AggregatorV3Interface
/// calls to the underlying oracle adapter. The registry reference is updatable
/// by the admin, allowing oracle swaps without protocol governance.
/// Deploy multiple proxy instances from the same beacon for different protocols.
contract PassthroughProtocolAdapter is AggregatorV3Interface, ICloneableV2, Initializable {
    /// @dev The oracle registry for looking up the oracle adapter.
    OracleRegistry public registry;
    /// @dev The vault address this adapter serves.
    address public vault;
    /// @dev Admin address for governance actions.
    address public admin;

    /// @dev Emitted when the adapter is initialized.
    event PassthroughProtocolAdapterInitialized(address indexed sender, PassthroughProtocolAdapterConfig config);
    /// @dev Emitted when the registry reference is updated.
    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    /// @dev Emitted when the admin is changed.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    constructor() {
        _disableInitializers();
    }

    /// As per ICloneableV2, this overload MUST always revert. Documents the
    /// signature of the initialize function.
    /// @param config The initialization configuration.
    function initialize(PassthroughProtocolAdapterConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        PassthroughProtocolAdapterConfig memory config = abi.decode(data, (PassthroughProtocolAdapterConfig));

        if (address(config.registry) == address(0)) revert ZeroRegistry();
        if (config.vault == address(0)) revert ZeroVault();
        if (config.admin == address(0)) revert ZeroAdmin();

        registry = config.registry;
        vault = config.vault;
        admin = config.admin;

        emit PassthroughProtocolAdapterInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Update the registry reference. Admin only.
    function setRegistry(OracleRegistry newRegistry) external onlyAdmin {
        if (address(newRegistry) == address(0)) revert ZeroRegistry();
        emit RegistrySet(address(registry), address(newRegistry));
        registry = newRegistry;
    }

    /// @notice Update the admin address. Admin only.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev Internal helper to get the oracle from registry and revert if not found.
    function _getOracle() internal view returns (AggregatorV3Interface) {
        AggregatorV3Interface oracle = registry.getOracle(vault);
        if (address(oracle) == address(0)) revert OracleNotFound();
        return oracle;
    }

    /// @inheritdoc AggregatorV3Interface
    function decimals() external view override returns (uint8) {
        return _getOracle().decimals();
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external view override returns (string memory) {
        return _getOracle().description();
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external view override returns (uint256) {
        return _getOracle().version();
    }

    /// @inheritdoc AggregatorV3Interface
    function latestAnswer() external view override returns (int256) {
        return _getOracle().latestAnswer();
    }

    /// @inheritdoc AggregatorV3Interface
    // slither-disable-next-line unused-return
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return _getOracle().latestRoundData();
    }
}
