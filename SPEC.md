# 🔮 ST0x Oracle Adapters Specification

**Repository:** `st0x.oracle`
**Version:** 2.0
**Status:** Draft
**Date:** 2026-02-06

---

## 1. Problem Statement

ST0x wrapped tokenized equities (ERC-4626 vault shares) need to integrate with DeFi lending protocols (Morpho Blue, Aave V3, Compound V3, and future protocols) to enable borrowing against tokenized stock collateral. The oracle prices vault shares by combining the Pyth price of the underlying equity with the vault's assets-per-share ratio. Each protocol has its own oracle interface requirements:

- **Morpho Blue**: Expects `IOracle.price()` returning a `uint256` scaled to 1e36
- **Aave V3**: Expects Chainlink's `AggregatorV3Interface` with `latestAnswer()` and `latestRoundData()`
- **Compound V3 (Comet)**: Expects Chainlink's `AggregatorV3Interface` with 8 decimal precision

The underlying price source is **Pyth Network**, which provides NBBO pricing for equities.

**Key challenges:**

1. Different protocols expect different interfaces and scaling
2. Oracle addresses are often immutable once set in lending markets (especially Morpho)
3. Corporate actions (splits, dividends) require pausing price feeds temporarily
4. Upgrades to one layer shouldn't require upgrades to another
5. Swapping oracles requires updating multiple protocol adapters individually

---

## 2. Goals

1. **True onchain modularity**: Oracle adapters and protocol adapters are separate deployments
2. **Industry standard interface**: Use Chainlink's `AggregatorV3Interface` as the contract boundary
3. **Swappable sources**: Protocol adapters can point to any oracle (Pyth today, Chainlink tomorrow)
4. **Independent upgrade paths**: Fix bugs in Pyth parsing without touching protocol adapters
5. **Beacon proxy pattern**: All layers use beacon proxies per `st0x.deploy` patterns
6. **Centralized oracle management**: Single registry update propagates to all protocol adapters

### 2.1 Relationship to rain.pyth

| Aspect | rain.pyth | st0x.oracle |
|--------|-----------|-------------|
| Purpose | Rain interpreter word | DeFi protocol integration |
| Interface | Returns `Float` (Rain format) | Returns `int256` (8 decimals) |
| Lookup | Runtime symbol lookup | Per-token deployed proxy |
| Pattern | Direct deployment | BeaconSetDeployer pattern |
| Governance | None (stateless) | Admin controls (pause, setPriceId) |

**What we reuse from rain.pyth:**

- `LibPyth.getPriceFeedContract(block.chainid)` - derives Pyth contract address at runtime (audited code)
- Price feed ID constants for all supported equities

---

## 3. Architecture Overview

```
PROTOCOL ADAPTERS
(indirection layer - looks up oracle from registry)

┌─────────────────┐  ┌────────────────────────────────────┐
│ MorphoAdapter   │  │ PassthroughAdapter                 │
│                 │  │ (multiple instances: Aave,         │
│ IOracle         │  │  Compound, future protocols)       │
│ (8→36 dec)      │  │ AggregatorV3 (passthrough)         │
│                 │  │                                    │
│ stores:         │  │ stores:                            │
│  - registry     │  │  - registry                        │
│  - vault        │  │  - vault                           │
└───────┬─────────┘  └───────────────┬────────────────────┘
        │                            │
        └────────────┬───────────────┘
                     ▼
           ┌─────────────────────────┐
           │     OracleRegistry      │  ← centralized vault→oracle mapping
           │                         │
           │  getOracle(vault)       │
           │  setOracle(vault, oracle)│
           │  setOracleBulk(...)     │
           └───────────┬─────────────┘
                       │
                       ▼
           ┌─────────────────────────┐
           │  AggregatorV3Interface  │  ← industry standard
           └─────────────────────────┘
                     ▲
          ┌──────────┴───────────────┐
          │       implements         │
          ▼                          ▼
┌─────────────────────┐    ┌─────────────────────┐
│ PythOracleAdapter   │    │ ChainlinkOracle     │
│                     │    │ Adapter (future)    │
│ Governance:         │    │                     │
│  - set priceId      │    │                     │
│  - set maxAge       │    │                     │
│  - pause/unpause    │    │                     │
└─────────────────────┘    └─────────────────────┘

ORACLE ADAPTERS
(canonical oracle per asset, all governance here)
```

**Why a registry layer:**

Without registry:
- Each protocol adapter stores its own oracle reference
- Pyth dies → Need to call `setOracle()` on every protocol adapter individually
- N vaults × M protocols = N×M `setOracle()` calls

With registry:
- Protocol adapters look up oracle from registry at runtime
- Pyth dies → Call `registry.setOracle(vault, chainlinkOracle)` once
- N vaults = N `setOracle()` calls (regardless of protocol count)

**Why protocol adapters still exist (even with registry):**

Without protocol adapter:
- Aave/Compound points directly to `PythOracleAdapter`
- Pyth dies → Need Aave/Compound governance to update their oracle registry
- ST0x has no control over the switch

With protocol adapter:
- Aave/Compound points to `PassthroughProtocolAdapter`
- Pyth dies → ST0x calls `registry.setOracle(vault, chainlinkOracleAdapter)`
- Protocol is unaware, no governance action needed on their side

---

## 4. OracleRegistry Implementation

Centralized vault→oracle mapping. Beacon proxy pattern.

**Storage:**

```solidity
address public admin;
mapping(address vault => AggregatorV3Interface oracle) internal _oracles;
```

**Functions:**

```solidity
/// @notice Set or update the oracle for a vault. Admin only.
/// @dev Upsert semantics - works for both new registration and updates.
function setOracle(address vault, AggregatorV3Interface oracle) external onlyAdmin;

/// @notice Bulk set or update oracles for multiple vaults. Admin only.
function setOracleBulk(address[] calldata vaults, AggregatorV3Interface[] calldata oracles) external onlyAdmin;

/// @notice Get the oracle for a vault.
/// @return The oracle adapter, or address(0) if not registered.
function getOracle(address vault) external view returns (AggregatorV3Interface);
```

**Events:**

- `OracleRegistryInitialized(address indexed sender, OracleRegistryConfig config)`
- `OracleSet(address indexed vault, address indexed oldOracle, address indexed newOracle)` — `oldOracle` is `address(0)` for new registrations

**Errors:**

- `OnlyAdmin()` — caller is not admin
- `ZeroAdmin()` — zero admin address in config
- `ZeroVault()` — zero vault address
- `ZeroOracle()` — zero oracle address
- `ArrayLengthMismatch()` — vaults and oracles arrays have different lengths

---

## 5. Protocol Adapter Types

| Protocol | Interface | Adapter Type |
|----------|-----------|-------------|
| Morpho Blue | `IOracle.price()` (36 dec) | `MorphoProtocolAdapter` • scales 8→36 |
| Aave V3 | `AggregatorV3Interface` (8 dec) | `PassthroughProtocolAdapter` instance |
| Compound V3 | `AggregatorV3Interface` (8 dec) | `PassthroughProtocolAdapter` instance |
| Future Chainlink-compatible | `AggregatorV3Interface` (8 dec) | `PassthroughProtocolAdapter` instance |

**Two adapter contracts (not three):**

- `MorphoProtocolAdapter` - scales 8→36 decimals
- `PassthroughProtocolAdapter` - used by Aave, Compound, any Chainlink-compatible protocol

Deploy multiple proxy *instances* from the same beacon for different protocols.

---

## 6. PythOracleAdapter Implementation

**Storage:**

```solidity
address public vault;            // ERC-4626 vault, set once, no setter
bytes32 public priceId;          // Pyth feed ID for underlying asset
uint256 public maxAge;           // Max acceptable price age
bool public paused;              // Emergency pause
address public admin;            // Admin for governance
```

Note: No `pyth` address storage - derived from `LibPyth.getPriceFeedContract(block.chainid)` at runtime.

**Price Formula:**

```
vaultSharePrice = pythPrice * vault.totalAssets() / vault.totalSupply()
```

The oracle prices ERC-4626 vault shares by combining the Pyth price of the underlying equity with the vault's assets-per-share ratio. This correctly handles stock splits (totalAssets increases), dividend reinvestment (totalAssets increases), and the wrapped token premium/discount.

**Implementation:**

```solidity
import {LibPyth} from "rain.pyth/src/lib/pyth/LibPyth.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";

function latestAnswer() external view override returns (int256) {
    _validateNotPaused();

    IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
    PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(priceId, maxAge);

    return _vaultSharePrice(priceData);
}

function _vaultSharePrice(PythStructs.Price memory priceData) internal view returns (int256) {
    int256 price8 = _conservativeScaledPrice(priceData);

    IERC4626 vaultContract = IERC4626(vault);
    uint256 totalAssets = vaultContract.totalAssets();
    uint256 totalSupply = vaultContract.totalSupply();

    if (totalSupply == 0) revert ZeroVaultSupply();

    return int256(uint256(price8) * totalAssets / totalSupply);
}
```

---

## 7. PassthroughProtocolAdapter Implementation

For protocols using `AggregatorV3Interface` (Aave V3, Compound V3, future Chainlink-compatible protocols):

```solidity
contract PassthroughProtocolAdapter is ICloneableV2, Initializable {
    OracleRegistry public registry;   // Registry for oracle lookup
    address public vault;             // Vault this adapter serves
    address public admin;             // Admin for governance

    function setRegistry(OracleRegistry newRegistry) external onlyAdmin {
        if (address(newRegistry) == address(0)) revert ZeroRegistry();
        emit RegistrySet(address(registry), address(newRegistry));
        registry = newRegistry;
    }

    function _getOracle() internal view returns (AggregatorV3Interface) {
        AggregatorV3Interface oracle = registry.getOracle(vault);
        if (address(oracle) == address(0)) revert OracleNotFound();
        return oracle;
    }

    function decimals() external view returns (uint8) {
        return _getOracle().decimals();
    }

    function latestAnswer() external view returns (int256) {
        return _getOracle().latestAnswer();
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return _getOracle().latestRoundData();
    }
}
```

**Usage:**

- Deploy one proxy instance for Aave (AAPL)
- Deploy another proxy instance for Compound (AAPL)
- Both share the same beacon and implementation
- Both point to the same registry and look up oracle for their vault
- Changing the oracle in the registry updates both adapters

---

## 8. MorphoProtocolAdapter Implementation

Morpho Blue requires `IOracle.price()` returning 36-decimal scaled price:

```solidity
contract MorphoProtocolAdapter is IOracle, ICloneableV2, Initializable {
    OracleRegistry public registry;   // Registry for oracle lookup
    address public vault;             // Vault this adapter serves
    address public admin;             // Admin for governance

    function setRegistry(OracleRegistry newRegistry) external onlyAdmin {
        if (address(newRegistry) == address(0)) revert ZeroRegistry();
        emit RegistrySet(address(registry), address(newRegistry));
        registry = newRegistry;
    }

    function price() external view override returns (uint256) {
        AggregatorV3Interface oracle = registry.getOracle(vault);
        if (address(oracle) == address(0)) revert OracleNotFound();

        int256 answer = oracle.latestAnswer();
        if (answer <= 0) revert NonPositivePrice();

        // Scale from 8 decimals to 36 decimals
        return uint256(answer) * 1e28;
    }
}
```

---

## 9. BeaconSetDeployer Pattern

Following `st0x.deploy` patterns:

**Oracle Registry:**

```solidity
contract OracleRegistryBeaconSetDeployer {
    IBeacon public immutable I_ORACLE_REGISTRY_BEACON;

    function newOracleRegistry(OracleRegistryConfig memory config)
        external returns (OracleRegistry);
}
```

**Oracle Adapter Layer:**

```solidity
contract PythOracleAdapterBeaconSetDeployer {
    IBeacon public immutable I_PYTH_ORACLE_ADAPTER_BEACON;

    function newPythOracleAdapter(PythOracleAdapterConfig memory config)
        external returns (PythOracleAdapter);
}
```

**Protocol Adapter Layer:**

```solidity
contract PassthroughProtocolAdapterBeaconSetDeployer {
    IBeacon public immutable I_PASSTHROUGH_PROTOCOL_ADAPTER_BEACON;

    function newPassthroughProtocolAdapter(
        OracleRegistry registry,
        address vault,
        address admin
    ) external returns (PassthroughProtocolAdapter);
}

contract MorphoProtocolAdapterBeaconSetDeployer {
    IBeacon public immutable I_MORPHO_PROTOCOL_ADAPTER_BEACON;

    function newMorphoProtocolAdapter(
        OracleRegistry registry,
        address vault,
        address admin
    ) external returns (MorphoProtocolAdapter);
}
```

---

## 10. Deployment Flow

**Initial deployment (once per chain):**

1. Deploy OracleRegistryV1 implementation
2. Deploy OracleRegistryBeaconSetDeployer (creates beacon internally)
3. Deploy the canonical OracleRegistry proxy
4. Deploy PythOracleAdapterV1 implementation
5. Deploy PythOracleAdapterBeaconSetDeployer
6. Deploy MorphoProtocolAdapterV1 implementation
7. Deploy MorphoProtocolAdapterBeaconSetDeployer
8. Deploy PassthroughProtocolAdapterV1 implementation
9. Deploy PassthroughProtocolAdapterBeaconSetDeployer
10. Deploy OracleUnifiedDeployer

**For a new vault (e.g., wrapped AAPL):**

```solidity
// Step 1: Deploy oracle + protocol adapters
OracleUnifiedDeployer.newOracleAndProtocolAdapters(
    vault,          // Wrapped AAPL ERC-4626 vault address
    priceId,        // AAPL/USD feed ID (from LibPyth constants)
    60,             // maxAge in seconds
    registry        // The canonical OracleRegistry
);
// Returns oracleAdapter, morphoAdapter, passthroughAdapter addresses

// Step 2: Register oracle in registry (admin action, separate tx)
registry.setOracle(vault, oracleAdapter);
```

**Why two-step deployment:**

- `OracleUnifiedDeployer` can be called by anyone to deploy adapters
- Only registry admin can register oracles
- Separation prevents unauthorized oracle registration

---

## 11. Repository Structure

```
st0x.oracle/
├── lib/
│   ├── rain.pyth/                              # For LibPyth
│   └── pyth-sdk-solidity/                      # Pyth structs
├── src/
│   ├── concrete/
│   │   ├── oracle/
│   │   │   └── PythOracleAdapter.sol
│   │   ├── registry/
│   │   │   └── OracleRegistry.sol              # Centralized vault→oracle mapping
│   │   ├── protocol/
│   │   │   ├── MorphoProtocolAdapter.sol       # Scales 8→36, uses registry
│   │   │   └── PassthroughProtocolAdapter.sol  # For Aave, Compound, uses registry
│   │   └── deploy/
│   │       ├── OracleRegistryBeaconSetDeployer.sol
│   │       ├── PythOracleAdapterBeaconSetDeployer.sol
│   │       ├── MorphoProtocolAdapterBeaconSetDeployer.sol
│   │       ├── PassthroughProtocolAdapterBeaconSetDeployer.sol
│   │       └── OracleUnifiedDeployer.sol
│   └── lib/
│       └── LibProdDeploy.sol
└── test/
```

---

## 12. LibPyth Usage

**Runtime (in PythOracleAdapter):**

```solidity
// No pyth address stored - derived at runtime from audited code
IPyth pyth = LibPyth.getPriceFeedContract(block.chainid);
```

**Constants (for deployment):**

```solidity
// From LibPyth.sol - already mapped
bytes32 constant PRICE_FEED_ID_EQUITY_US_AAPL_USD = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
bytes32 constant PRICE_FEED_ID_EQUITY_US_TSLA_USD = 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1;
bytes32 constant PRICE_FEED_ID_EQUITY_US_NVDA_USD = 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593;
// ... GOOG, AMZN, MSFT, META, GME, MSTR, COIN, etc.

// Chain ID → Pyth contract
IPyth constant PRICE_FEED_CONTRACT_BASE = IPyth(0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a);
```

---

## 13. Governance

All admin roles held by founder multisig:

- **Beacon Owner**: Can upgrade implementation
- **Registry Admin**: Can register/update vault→oracle mappings
- **Oracle Admin**: Can update priceId, maxAge, pause/unpause
- **Protocol Adapter Admin**: Can update registry reference (opt-out mechanism)

No separation of roles.

---

## 14. Upgrade & Migration Scenarios

| Scenario | Action | Unchanged |
|----------|--------|-----------|
| Bug in Pyth price parsing | Upgrade PythOracleBeacon implementation | Registry, all protocol adapters |
| Bug in Morpho scaling | Upgrade MorphoAdapterBeacon implementation | Registry, all oracle adapters |
| Add Aave support | Deploy PassthroughAdapter proxy pointing to existing registry | Everything else |
| Pyth dies, switch to Chainlink | Deploy ChainlinkOracleAdapter, call `registry.setOracle(vault, chainlinkOracle)` | Protocol adapters automatically use new oracle |
| Corporate action (AAPL split) | Auto-pause via `ICorporateActionsV1`, no admin action — see § 16 | Protocol adapters unaware |
| Retune corporate-action pause window | Deploy a new oracle proxy with the new config, `registry.setOracle(vault, newOracle)` — pause-window fields are immutable post-init | Protocol adapters automatically use new oracle |
| Bulk oracle update (10 vaults) | `registry.setOracleBulk(vaults, oracles)` | Single tx updates all |
| Protocol adapter wants different registry | `adapter.setRegistry(alternativeRegistry)` | Other adapters unaffected |

---

## 15. Security Considerations

1. **Negative prices**: Pyth prices can theoretically be negative; handle appropriately (revert)
2. **Confidence intervals**: Pyth provides confidence data; consider rejecting wide confidence
3. **Overflow**: Ensure scaling math cannot overflow (checked arithmetic in 0.8.25)
4. **Corporate actions**: Auto-pause via `ICorporateActionsV1` blocks `latestAnswer` / `latestRoundData` inside a configurable window around any scheduled action; manual `setPaused` remains an independent escape hatch — see § 16
5. **Zero vault supply**: Revert when vault has no shares minted (no valid price)
6. **Vault ratio manipulation**: Vault totalAssets/totalSupply is trusted — vault must be a known st0x deployment
7. **Oracle not registered**: Protocol adapters revert with `OracleNotFound` if vault not in registry
8. **Registry admin trust**: Registry admin can point any vault to any oracle — trust assumption

---

## 16. Corporate-Action-Aware Auto-Pause

### 16.1 Why

Manual `setPaused(true)` works but requires the admin to be awake, online, and on the right multisig at the right minute. A scheduled corporate action (today: stock splits) is on-chain data with a known `effectiveTime`. The oracle should read that data and pause itself around the action — keeping on-chain and off-chain in sync without an admin in the loop.

The vault is rebasing, so we don't read or expose token multipliers. The existing `vaultSharePrice = pythPrice * totalAssets / totalSupply` formula is correct immediately after `effectiveTime` — `totalAssets` and `totalSupply` both reflect post-rebase values atomically. The pause window exists to cover the **operational window** in which the off-chain feed (Pyth) and on-chain state are not guaranteed to agree (Pyth split-adjustment latency, RPC propagation, integrator caches), not the on-chain math.

### 16.2 Configuration

Per-oracle, set at initialize, **immutable thereafter**:

```solidity
struct CorporateActionPauseConfig {
    /// Address implementing ICorporateActionsV1. May be the same as `vault`
    /// if the vault itself implements the interface, or a separate vault
    /// (e.g. the underlying rebasing token under a wtStock wrapper). Zero
    /// address disables auto-pause entirely (legacy/manual-only mode).
    address corporateActionsVault;
    /// Bitmap of action types that trigger an auto-pause. Use
    /// `ACTION_TYPE_STOCK_SPLIT_V1` (`1 << 1`) for splits only, or
    /// `type(uint256).max` to catch every future action type. Note that
    /// `1 << 0` is reserved for `ACTION_TYPE_INIT_V1` (the per-vault
    /// initialisation marker created once on first scheduling) and is
    /// not a meaningful pause trigger.
    uint256 actionTypeMask;
    /// Seconds before a pending action's `effectiveTime` to start pausing.
    uint64 pauseTimeBefore;
    /// Seconds after a completed action's `effectiveTime` to keep pausing.
    uint64 pauseTimeAfter;
}
```

No setters. To change any of these (opt into a new action type, retune the window), deploy a new oracle proxy with the new config and switch over via `OracleRegistry.setOracle(vault, newOracle)`. This matches the existing pattern for `priceId` / `maxAge` on `PythOracleAdapter` and the § 14 migration flow ("Pyth dies, switch to Chainlink"). The manual `setPaused` flag remains the operational escape hatch for anything that genuinely can't wait for a redeploy.

Defaults baked into deployment scripts (not the contract):

| Field | Default | Reason |
|---|---|---|
| `corporateActionsVault` | underlying rebasing vault | wtStock wraps a StoxReceiptVault that implements `ICorporateActionsV1` |
| `actionTypeMask` | `ACTION_TYPE_STOCK_SPLIT_V1` (`1 << 1`) | Only currently-schedulable action type; opt-in to future types per-deployment |
| `pauseTimeBefore` | `3600` (1 hour) | Lets integrators wind down without an admin call |
| `pauseTimeAfter` | `3600` (1 hour) | Covers Pyth split-adjustment latency + RPC propagation |

`corporateActionsVault == address(0)` disables auto-pause — useful for the brief migration period when an oracle is redeployed against a vault that hasn't yet been upgraded to expose `ICorporateActionsV1`.

### 16.3 Pause window definition

Let `now = block.timestamp`. The oracle is auto-paused iff **either**:

1. There is a **pending** action `A` with `actionType & mask != 0` and `effectiveTime - pauseTimeBefore ≤ now < effectiveTime`. The earliest pending action governs — if it doesn't trigger, no later one will (their effectiveTimes are strictly larger).

2. There is a **completed** action `A` with `actionType & mask != 0` and `effectiveTime ≤ now ≤ effectiveTime + pauseTimeAfter`. The latest completed action governs — if it doesn't trigger, no earlier one will (their effectiveTimes are strictly smaller).

This requires at most two `ICorporateActionsV1` calls per `latestAnswer` / `latestRoundData`:

- `earliestActionOfType(mask, PENDING)` — finds the earliest pending action.
- `latestActionOfType(mask, COMPLETED)` — finds the latest completed action.

Cancelled actions are **unlinked** from the list (`LibCorporateAction.cancel` sets `prev = next = effectiveTime = 0`) and unreachable from `earliestActionOfType` / `latestActionOfType` traversal, so they neither trigger pauses nor require explicit filtering.

### 16.4 Interaction with manual pause

Independent. Either condition pauses the oracle:

```solidity
if (manualPaused) revert OraclePausedManual();
if (inPauseWindow(...)) revert OraclePausedCorporateAction(effectiveTime);
```

Distinct errors so integrators can disambiguate via static-call introspection or simulation. The admin can still `setPaused(true)` independently and `setPaused(false)` independently — that flag is unchanged.

### 16.5 Multiple pending actions

Each pending action is evaluated against its own `effectiveTime`. The implementation only checks the **earliest** pending — that's the one closest to `now` — because a `pauseTimeBefore` window that doesn't reach the earliest pending can't reach any later pending either.

If two pending actions are scheduled close enough in time that their windows overlap, the oracle stays paused continuously through both. This is correct behaviour and needs no special handling.

### 16.6 Partial migration

`effectiveTime <= now` makes the action complete and the rebase atomically visible in `totalAssets` / `totalSupply`. Per-account migrations happen lazily on first touch and don't affect the wrapper's view of the underlying balance (the wrapper holds aggregate underlying, not per-account positions). So the share-price formula is correct from `effectiveTime` onward.

`pauseTimeAfter` exists to cover the gap between on-chain effectiveness and **off-chain catch-up** — Pyth split-adjusting their feed, RPC propagation, indexer reorg buffers — not partial migration.

### 16.7 Action-type forward compatibility

The bitmap mask design from `ICorporateActionsV1` propagates: new action types added later (e.g. dividends, mergers) are new bit positions. Existing deployments are unaffected — their mask only matches `1 << 1` (splits). To opt new oracles into a new type, deploy with the union mask (`(1 << 1) | (1 << N)`).

Mask = 0 means "match nothing"; equivalent to disabling auto-pause but keeping `corporateActionsVault` non-zero. We don't recommend it (just leave `corporateActionsVault = address(0)` instead) but we don't reject it either.

### 16.8 Errors

```solidity
error OraclePausedManual();
error OraclePausedCorporateAction(uint64 effectiveTime);
```

`OraclePaused` (existing) is removed in favour of the disambiguated pair. This is a breaking interface change for any caller that handled `OraclePaused` by selector — flagged in the migration plan (RAI-323).

`effectiveTime` on `OraclePausedCorporateAction` lets integrators surface "oracle paused for action at HH:MM:SS" in their UIs without a separate storage read.

### 16.9 Gas

Two view calls into the vault per `latestAnswer` / `latestRoundData`. Each call walks at most a handful of nodes — pending and completed action lists are small (single-digit entries per vault per year). No storage writes during pause checks. Acceptable for an oracle.

---

## 17. References

- **rain.pyth**: https://github.com/rainlanguage/rain.pyth
- **st0x.deploy**: https://github.com/S01-Issuer/st0x.deploy
- **Pyth Network**: https://docs.pyth.network/
- **Chainlink AggregatorV3Interface**: https://github.com/smartcontractkit/chainlink
