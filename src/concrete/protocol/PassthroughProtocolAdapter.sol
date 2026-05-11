// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";
import {OracleRegistry} from "src/concrete/registry/OracleRegistry.sol";

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when a zero address is provided for the registry.
error ZeroRegistry();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when the currently-pointed registry has no entry for
/// `vault`. This includes both the canonical-registry-never-registered case
/// AND the `setRegistry`-pointed-elsewhere case (where the admin swapped
/// the registry to one that doesn't know about this vault).
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
/// Chainlink-compatible protocol. Passes through all AggregatorV2V3Interface
/// calls to the underlying oracle adapter. The registry reference is updatable
/// by the admin, allowing oracle swaps without protocol governance.
///
/// PRECONDITION: All oracles registered for vaults consumed by this adapter
/// MUST report `decimals() == 8`. Aave V3 and Compound V3 cache `decimals()`
/// at registration time and hard-code the 8-decimal expectation; pointing
/// the registry to an oracle with a different precision will silently scale
/// prices wrong (e.g. an 18-decimal oracle yields 1e10× prices on Aave).
/// SPEC §15's registry-admin-trust assumption applies.
/// Deploy multiple proxy instances from the same beacon for different protocols.
contract PassthroughProtocolAdapter is AggregatorV2V3Interface, ICloneableV2, Initializable {
    /// @dev The oracle registry for looking up the oracle adapter.
    OracleRegistry public registry;
    /// @dev The vault address this adapter serves.
    address public vault;
    /// @dev Admin address for governance actions.
    address public admin;

    /// @notice Emitted when the adapter is initialized.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event PassthroughProtocolAdapterInitialized(address indexed sender, PassthroughProtocolAdapterConfig config);
    /// @notice Emitted when the registry reference is updated.
    /// @param oldRegistry The previous registry address.
    /// @param newRegistry The new registry address.
    event RegistrySet(address indexed oldRegistry, address indexed newRegistry);
    /// @notice Emitted when the admin is changed.
    /// @param oldAdmin The previous admin address.
    /// @param newAdmin The new admin address.
    event AdminSet(address indexed oldAdmin, address indexed newAdmin);

    constructor() {
        _disableInitializers();
    }

    /// @notice Documents the typed signature of the initialize function. Per
    /// ICloneableV2 this overload MUST always revert; callers should use the
    /// `bytes calldata` overload instead.
    /// @dev Always reverts with `InitializeSignatureFn`.
    /// @param config The initialization configuration. Ignored.
    /// @return Never returns; included only for the function signature.
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
    /// @param newRegistry The new oracle registry address.
    function setRegistry(OracleRegistry newRegistry) external onlyAdmin {
        if (address(newRegistry) == address(0)) revert ZeroRegistry();
        emit RegistrySet(address(registry), address(newRegistry));
        registry = newRegistry;
    }

    /// @notice Update the admin address. Admin only.
    /// @dev One-step transfer — the new admin takes effect immediately. A
    /// wrong `newAdmin` will lock the adapter's governance permanently:
    /// `setRegistry` will become uncallable. The only recovery is
    /// `OracleRegistry.setOracle(vault, newOracle)` to redirect downstream
    /// protocols to a different `PassthroughProtocolAdapter` proxy. Use a
    /// multisig that cannot be misaddressed.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @dev Internal helper to get the oracle from registry and revert if not found.
    function _getOracle() internal view returns (AggregatorV2V3Interface) {
        AggregatorV2V3Interface oracle = registry.getOracle(vault);
        if (address(oracle) == address(0)) revert OracleNotFound();
        return oracle;
    }

    /// @inheritdoc AggregatorV2V3Interface
    function decimals() external view override returns (uint8) {
        return _getOracle().decimals();
    }

    /// @inheritdoc AggregatorV2V3Interface
    function description() external view override returns (string memory) {
        return _getOracle().description();
    }

    /// @inheritdoc AggregatorV2V3Interface
    function version() external view override returns (uint256) {
        return _getOracle().version();
    }

    /// @inheritdoc AggregatorV2V3Interface
    function latestAnswer() external view override returns (int256) {
        return _getOracle().latestAnswer();
    }

    /// @inheritdoc AggregatorV2V3Interface
    /// @dev `roundId` and `answeredInRound` are forwarded verbatim from the
    /// registered upstream oracle. They are NOT normalized across
    /// `OracleRegistry.setOracle` swaps; integrators that rely on Chainlink's
    /// monotonically-increasing-roundId guarantee should not register this
    /// adapter unless the registry's oracle is locked or the integrator's
    /// staleness check tolerates discontinuities.
    // slither-disable-next-line unused-return
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return _getOracle().latestRoundData();
    }

    /// @inheritdoc AggregatorV2V3Interface
    // slither-disable-next-line unused-return
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return _getOracle().getRoundData(_roundId);
    }
}
