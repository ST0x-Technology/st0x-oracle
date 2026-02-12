# st0x.oracle

Oracle adapter system that bridges Pyth Network price feeds to DeFi lending protocols (Morpho Blue, Aave V3, Compound V3). Three-layer architecture: oracle adapters (price source), oracle registry (centralized vault→oracle mapping), and protocol adapters (protocol-specific interface). Allows independent upgrades, oracle swaps via single registry update, and protocol adapters that can opt-out to alternative registries.

## Architecture

```
  PROTOCOL ADAPTERS (looks up oracle from registry)

  ┌───────────────────────┐   ┌──────────────────────────────────────┐
  │ MorphoProtocolAdapter │   │ PassthroughProtocolAdapter           │
  │ IOracle (8→36 dec)    │   │ (instances: Aave, Compound, ...)     │
  │                       │   │ AggregatorV3Interface passthrough    │
  │ stores: registry,     │   │                                      │
  │         vault         │   │ stores: registry, vault              │
  └──────────┬────────────┘   └──────────────────┬───────────────────┘
             │                                   │
             └────────────────┬──────────────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │    OracleRegistry     │  ← centralized vault→oracle mapping
                  │                       │
                  │  getOracle(vault)     │
                  │  setOracle(vault, o)  │
                  │  setOracleBulk(...)   │
                  └───────────┬───────────┘
                              │
                              ▼
                  ┌───────────────────────┐
                  │ AggregatorV3Interface │  ← contract boundary
                  └───────────────────────┘
                              ▲
                              │
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
  ┌──────────────────────┐   ┌──────────────────────┐
  │ PythOracleAdapter    │   │ Future adapters      │
  │ Pyth → 8 dec         │   │ (Chainlink etc)      │
  │ pause, admin         │   │                      │
  └──────────────────────┘   └──────────────────────┘

  ORACLE ADAPTERS (canonical price source per asset)
```

**Oracle layer** -- one `PythOracleAdapter` per vault, implements `AggregatorV3Interface` at 8 decimals. Prices vault shares as `pythPrice * totalAssets / totalSupply`. Governance controls (pause for corporate actions) live here.

**Registry layer** -- `OracleRegistry` maintains centralized `vault → oracle` mapping. Single `setOracle()` call updates the oracle for all protocol adapters serving that vault. Supports bulk updates via `setOracleBulk()`.

**Protocol layer** -- `PassthroughProtocolAdapter` (Aave/Compound/any Chainlink-compatible) and `MorphoProtocolAdapter` (scales 8 to 36 decimals). Each stores `registry + vault` and looks up oracle at runtime. Can opt-out via `setRegistry()` to point to an alternative registry.

**Deployers** -- beacon proxy pattern via `st0x.deploy`. `OracleUnifiedDeployer` deploys an oracle adapter + all protocol adapters for a new vault. Admin must call `registry.setOracle()` separately to register the oracle.

## Setup

This project uses Nix flakes for reproducible toolchain management.

```bash
nix develop
```

## Build & Test

```bash
forge build
forge test
forge test -vvv          # verbose
forge fmt --check        # check formatting
```

Fork tests require a Base RPC URL:

```bash
export RPC_URL_BASE_FORK=<your-base-rpc-url>
forge test
```

## Repository Structure

```
src/
├── concrete/
│   ├── oracle/
│   │   └── PythOracleAdapter.sol
│   ├── registry/
│   │   └── OracleRegistry.sol
│   ├── protocol/
│   │   ├── MorphoProtocolAdapter.sol
│   │   └── PassthroughProtocolAdapter.sol
│   └── deploy/
│       ├── PythOracleAdapterBeaconSetDeployer.sol
│       ├── OracleRegistryBeaconSetDeployer.sol
│       ├── MorphoProtocolAdapterBeaconSetDeployer.sol
│       ├── PassthroughProtocolAdapterBeaconSetDeployer.sol
│       └── OracleUnifiedDeployer.sol
├── interface/
│   └── IAggregatorV3.sol
└── lib/
    └── LibProdDeploy.sol
test/
├── abstract/
│   ├── PythOracleAdapterTest.sol
│   └── OracleRegistryTest.sol
├── lib/
│   └── LibFork.sol
└── src/
    └── concrete/
        ├── deploy/
        ├── oracle/
        ├── registry/
        └── protocol/
```

## Dependencies

- [rain.pyth](https://github.com/rainlanguage/rain.pyth) -- `LibPyth.getPriceFeedContract()` and price feed ID constants
- [pyth-sdk-solidity](https://github.com/pyth-network/pyth-sdk-solidity) -- `IPyth`, `PythStructs`
- [st0x.deploy](https://github.com/S01-Issuer/st0x.deploy) -- `BeaconSetDeployer` pattern, `ICloneableV2`
- [openzeppelin-contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) -- `UpgradeableBeacon`, `BeaconProxy`, `Initializable`

## License

DCL-1.0
