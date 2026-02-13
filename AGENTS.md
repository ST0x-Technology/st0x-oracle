# AGENTS.md — st0x.oracle

## Build System

This repo uses **nix flakes** for all tooling. Do not use globally installed `forge` or `solc`.

```bash
# Enter the nix dev shell
nix develop

# Or run a single command
nix develop -c forge build
```

All commands below assume you are inside `nix develop`.

## Before Pushing

Run the full CI prelude locally before every push:

```bash
nix develop -c rainix-sol-prelude
```

This runs formatting, linting, and compilation — the same checks CI runs. If it fails locally, it will fail on CI.

At minimum:
1. `forge fmt` — auto-format all Solidity files
2. `forge build` — compile everything
3. `forge test` — run unit + fuzz tests

For fork tests (ProdFork.t.sol):
```bash
RPC_URL_BASE_FORK=https://mainnet.base.org forge test --match-contract ProdForkTest
```

## Address Checksums

Solidity requires EIP-55 checksummed addresses. When adding deployed addresses, use `cast to-check-sum-address` to get the correct casing:

```bash
cast to-check-sum-address 0xabcdef...
```

Do not use lowercase addresses from transaction receipts directly.

## Testing

- **Every feature needs tests.** No exceptions.
- **Use fuzz tests** wherever appropriate — especially for functions that take arbitrary inputs.
- **Prod fork tests** (`test/src/concrete/ProdFork.t.sol`) run against live Base mainnet state. They use skip modifiers (`onlyIfOracleDeployed`, etc.) so they pass vacuously before deployment and run against real contracts after.
- Fork tests can be merged before deployment — the skip modifiers handle this.

## Deployment

Deployments happen via GitHub Actions (`manual-sol-artifacts.yaml`), not locally.

1. Run the workflow with `network=base` and the appropriate `suite`
2. Parse deployed addresses from the workflow logs
3. PR the addresses into `src/lib/LibProdDeploy.sol` (for deployer addresses) or `test/src/concrete/ProdFork.t.sol` `LibProdOracles` (for oracle/adapter addresses)
4. Use `cast send` with `--interactive` for any onchain calls that need a private key

### Deployment Suites

- `pyth-oracle-adapter-beacon-set` — PythOracleAdapter beacon + impl
- `morpho-protocol-adapter-beacon-set` — MorphoProtocolAdapter beacon + impl
- `passthrough-protocol-adapter-beacon-set` — PassthroughProtocolAdapter beacon + impl
- `oracle-unified-deployer` — OracleUnifiedDeployer (stateless, calls beacon set deployers)
- `oracle-registry-beacon-set` — OracleRegistry beacon + impl

### Secret Naming Convention

Workflow secrets follow the `CI_DEPLOY_<NETWORK>_<SUFFIX>` pattern:
- `CI_DEPLOY_BASE_RPC_URL`
- `CI_DEPLOY_BASE_DEPLOYER_PRIVATE_KEY`
- `CI_DEPLOY_BASE_ETHERSCAN_API_KEY`
- `CI_DEPLOY_BASE_VERIFIER_URL` (use `https://api.etherscan.io/v2/api?chainid=8453`)

## Architecture

- **PythOracleAdapter** — wraps Pyth price feeds into AggregatorV3Interface (8 decimals)
- **MorphoProtocolAdapter** — scales oracle price to 36 decimals for Morpho
- **PassthroughProtocolAdapter** — passes oracle price through unchanged (AggregatorV3Interface)
- **OracleRegistry** — maps vault → oracle adapter. Protocol adapters look up their oracle from the registry at runtime.
- **OracleUnifiedDeployer** — deploys all three adapters for a vault in one call. Takes registry address as parameter.
- **Beacon pattern** — all contracts use UpgradeableBeacon proxies. `BEACON_INITIAL_OWNER` is `rainlang.eth` (`0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b`).

## Key Constants

- `BEACON_INITIAL_OWNER`: `0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b` (rainlang.eth)
- All deployer addresses are in `src/lib/LibProdDeploy.sol`
- All oracle instance addresses are in `test/src/concrete/ProdFork.t.sol` `LibProdOracles`
