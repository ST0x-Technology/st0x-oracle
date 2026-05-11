// SPDX-License-Identifier: LicenseRef-DCL-1.0
// SPDX-FileCopyrightText: Copyright (c) 2020 Rain Open Source Software Ltd
pragma solidity =0.8.25;

import {ICLONEABLE_V2_SUCCESS, ICloneableV2} from "rain.factory/interface/ICloneableV2.sol";
import {Initializable} from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import {AggregatorV2V3Interface} from "src/interface/IAggregatorV2V3.sol";

/// @dev Error raised when the caller is not the admin.
error OnlyAdmin();

/// @dev Error raised when a zero address is provided for the admin.
error ZeroAdmin();

/// @dev Error raised when a zero address is provided for the vault.
error ZeroVault();

/// @dev Error raised when a zero address is provided for the oracle.
error ZeroOracle();

/// @dev Error raised when array lengths do not match in bulk operations.
error ArrayLengthMismatch();

/// @dev Error raised when a bulk operation's input arrays exceed
/// `MAX_BULK_LENGTH`. Includes the offending length and the cap so a
/// multisig signer reviewing the revert can confirm the bound at a glance.
error BulkLengthExceeded(uint256 length, uint256 maxLength);

/// @dev Maximum number of (vault, oracle) pairs accepted in a single
/// `setOracleBulk` call. Sized to fit comfortably under any current EVM
/// L1/L2 block gas limit while leaving margin for log and call overhead.
uint256 constant MAX_BULK_LENGTH = 256;

/// @title OracleRegistryConfig
/// @notice Single-field config struct kept to mirror the BeaconSetDeployer
/// pattern used by sibling adapters; future fields can be added without an
/// ABI break for the initializer.
/// @param admin The admin address.
struct OracleRegistryConfig {
    address admin;
}

/// @title OracleRegistry
/// @notice Centralizes vault -> oracle adapter mappings. Protocol adapters
/// look up their oracle from the registry at runtime instead of storing a
/// direct reference. A single registry update propagates to all protocol
/// adapters for that vault automatically.
contract OracleRegistry is ICloneableV2, Initializable {
    /// @dev Admin address for governance actions.
    address public admin;
    /// @dev Mapping from vault address to oracle adapter.
    mapping(address vault => AggregatorV2V3Interface oracle) internal _oracles;

    /// @notice Emitted when the registry is initialized.
    /// @param sender The caller that initialized the proxy.
    /// @param config The initialization configuration.
    event OracleRegistryInitialized(address indexed sender, OracleRegistryConfig config);
    /// @notice Emitted when an oracle is set for a vault.
    /// @param vault The vault address.
    /// @param oldOracle The previous oracle adapter address (zero if none).
    /// @param newOracle The new oracle adapter address.
    event OracleSet(address indexed vault, address indexed oldOracle, address indexed newOracle);
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
    function initialize(OracleRegistryConfig memory config) external pure returns (bytes32) {
        (config);
        revert InitializeSignatureFn();
    }

    /// @inheritdoc ICloneableV2
    function initialize(bytes calldata data) external initializer returns (bytes32) {
        OracleRegistryConfig memory config = abi.decode(data, (OracleRegistryConfig));

        if (config.admin == address(0)) revert ZeroAdmin();

        admin = config.admin;

        emit OracleRegistryInitialized(msg.sender, config);

        return ICLONEABLE_V2_SUCCESS;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Update the admin address. Admin only.
    /// @dev One-step transfer — the new admin takes effect immediately. A
    /// wrong `newAdmin` will lock the registry's governance permanently:
    /// `setOracle` / `setOracleBulk` will become uncallable. There is no
    /// in-band recovery — downstream protocol adapters that look up via this
    /// registry will be stuck on their current oracle. Use a multisig that
    /// cannot be misaddressed.
    /// @param newAdmin The new admin address.
    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAdmin();
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Set or update the oracle for a vault. Admin only.
    /// @param vault The vault address.
    /// @param oracle The oracle adapter address.
    function setOracle(address vault, AggregatorV2V3Interface oracle) external onlyAdmin {
        if (vault == address(0)) revert ZeroVault();
        if (address(oracle) == address(0)) revert ZeroOracle();

        address oldOracle = address(_oracles[vault]);
        _oracles[vault] = oracle;

        emit OracleSet(vault, oldOracle, address(oracle));
    }

    /// @notice Bulk set or update oracles for multiple vaults. Admin only.
    /// @param vaults The vault addresses.
    /// @param oracles The oracle adapter addresses.
    function setOracleBulk(address[] calldata vaults, AggregatorV2V3Interface[] calldata oracles) external onlyAdmin {
        if (vaults.length != oracles.length) revert ArrayLengthMismatch();
        if (vaults.length > MAX_BULK_LENGTH) revert BulkLengthExceeded(vaults.length, MAX_BULK_LENGTH);

        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == address(0)) revert ZeroVault();
            if (address(oracles[i]) == address(0)) revert ZeroOracle();

            address oldOracle = address(_oracles[vaults[i]]);
            _oracles[vaults[i]] = oracles[i];

            emit OracleSet(vaults[i], oldOracle, address(oracles[i]));
        }
    }

    /// @notice Get the oracle for a vault.
    /// @param vault The vault address.
    /// @return The oracle adapter, or address(0) if not registered.
    function getOracle(address vault) external view returns (AggregatorV2V3Interface) {
        return _oracles[vault];
    }
}
