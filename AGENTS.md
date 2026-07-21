# AGENTS.md — st0x.oracle

## Build System

This repo uses **nix flakes** for all tooling. Do not use globally installed
`forge` or `solc`.

```bash
# Enter the nix dev shell
nix develop

# Or run a single command
nix develop -c forge build
```

All commands below assume you are inside `nix develop`.

On a fresh clone, `dependencies/` is gitignored — run `forge soldeer install`
once before any build/test/lint command (CI runs the same step in every job).

## Before Pushing

CI is the reusable `rainlanguage/rainix` sol workflows
(`.github/workflows/rainix-sol.yaml` → `rainix-sol.yaml@main`). Mirror every
gate locally before every push — if any fails locally, CI will fail too:

```bash
# 1. Formatting (CI runs --check; run plain `forge fmt` to fix)
forge fmt --check

# 2. Tests (unit + fuzz)
forge test -vvv

# 3. Static analysis (slither)
slither .

# 4. One contract per .sol file (Rain org convention)
rainix-sol-single-contract

# 5. License compliance (REUSE / DecentraLicense headers)
reuse lint
```

Three more org-wide gates CI enforces that have no local task:

- **No git submodules.** Dependencies come from soldeer (see `foundry.toml`
  `[dependencies]`), never `.gitmodules`.
- **No custom NatSpec tags.** `@custom:` is banned; document behavior in
  standard NatSpec (`@notice`/`@dev`/`@param`/`@return`). Sole exception:
  ERC-7201's exact `@custom:storage-location erc7201:` annotation.
- **No ignored/skipped tests.** Rust `#[ignore]`, JS `.skip`/`.only`, Solidity
  `xtest` renames, and any `vm.skip` are all banned. A test either runs and
  passes or is deleted.

## Slither Annotations

When slither flags false positives, suppress them with inline comments:

```solidity
// slither-disable-next-line reentrancy-events
```

Always add a comment explaining WHY the finding is a false positive. See
`DIAOracleUnifiedDeployer.newOracleWithWrapper` for an example.

## Address Checksums

Solidity requires EIP-55 checksummed addresses. When adding deployed addresses,
use `cast to-check-sum-address` to get the correct casing:

```bash
cast to-check-sum-address 0xabcdef...
```

Do not use lowercase addresses from transaction receipts directly.

## Testing

- **Every feature needs tests.** No exceptions.
- **Use fuzz tests** wherever appropriate — especially for functions that take
  arbitrary inputs.
- Unit tests live under `test/src/` mirroring the `src/` layout; shared
  mocks/harness contracts live in `test/mocks/` (one contract per file, like
  everything else).
- `test/src/e2e/DIAStackE2E.t.sol` exercises the full DIA stack (deployers →
  proxies → reads) without forking.

## Deployment

Deployments happen via GitHub Actions (`manual-sol-artifacts.yaml`), not
locally. The workflow runs `rainix-sol-artifacts`, which executes
`script/Deploy.sol:Deploy` with the chosen `DEPLOYMENT_SUITE`:

- `dia-oracle-unified-deployer` — DIA stack infra: fresh implementations, both
  beacon-set deployers, and the `DIAOracleUnifiedDeployer` composing them. No
  per-vault proxies are minted; each vault's `(oracle, wrapper)` pair is minted
  afterwards through the unified deployer with that vault's real
  corporate-action pause config.

`BEACON_INITIAL_OWNER` is **required** and must differ from the deploy key: the
beacon owner controls the implementation behind every proxy (every served
price), so it must be governance — a multisig — never the hot CI deploy key. The
workflow exposes it as a required dispatch input; a missing value fails the
deploy loudly.

1. Run the workflow with the target network, suite, and beacon owner
2. Record the deployed addresses from the workflow logs into
   `deployments/<network>.json` (see **Deployment records** below) and PR it —
   CI logs expire, so this committed file is the canonical record
3. Use `cast send` with `--interactive` for any onchain calls that need a
   private key

### Determinism

Proxies are minted via **CREATE2 with a config-derived salt**
(`salt = keccak256(abi.encode(initConfig))`), so a proxy's address is a
deterministic commitment to its config and re-running a deploy with identical
config reverts on the collision instead of forking a second divergent proxy. The
classic no-arg Zoltu pattern is deliberately **not** used: the beacon owner is a
required runtime input (governance), which is config that cannot be baked into
fixed init bytecode — CREATE2-salted minting is the determinism compatible with
runtime-owned beacons.

### Deployment records

Each chain's deployed addresses are committed under `deployments/<network>.json`
(the impls, beacons, beacon-set deployers, unified deployer, and — once deployed
— the signed-price singleton), so the canonical record survives the CI logs it
was parsed from. `DeploymentsRecord.t.sol` asserts the committed record stays
structurally complete (populated, checksummed, distinct addresses) so it can't
silently rot to zeros.

Note the recorded Base DIA impls predate this branch's ERC-7201 + hardening
changes, so on-chain bytecode intentionally differs from current source until a
redeploy / beacon upgrade reconciles them. A codehash prod-fork test (raindex
`LibRaindexDeployProd` pattern) is the right follow-up **once the stack is
redeployed onto the current impls at deterministic addresses** — it needs a live
deployment that matches source to be green, and a guaranteed Base fork RPC, so
it belongs in a scheduled workflow rather than the per-push run.

### Toolchain pins

Two independent rainix pins exist by design and are allowed to differ: CI runs
the reusable `rainlanguage/rainix` workflows at `@main` (org convention — a
rainix CI fix propagates instantly), which pin their own internal `RAINIX_SHA`;
local dev + `manual-sol-artifacts.yaml` use this repo's `flake.lock`. There is
no cross-pin sync check because the two serve different roles; bump `flake.lock`
with `nix flake update` when local tooling needs to catch up.

### Secret Naming Convention

The deploy signing key is **not** per-network: `manual-sol-artifacts.yaml` uses
`secrets.PRIVATE_KEY` for runs dispatched from `main` and
`secrets.PRIVATE_KEY_DEV` for any other ref (see its `DEPLOYMENT_KEY` env line).

Per-network secrets/vars follow the `CI_DEPLOY_<NETWORK>_<SUFFIX>` pattern:

- `CI_DEPLOY_BASE_RPC_URL`
- `CI_DEPLOY_BASE_ETHERSCAN_API_KEY`
- `CI_DEPLOY_BASE_VERIFY`
- `CI_DEPLOY_BASE_VERIFIER`
- `CI_DEPLOY_BASE_VERIFIER_URL` (use
  `https://api.etherscan.io/v2/api?chainid=8453`)

## Architecture

Two stacks share the repo — see `README.md` and `SPEC.md` for the full picture.

**DIA stack** (prices `wtStock` ERC-4626 vault shares for Chainlink-compatible
consumers):

- **DIAVaultOracle** — reads the underlying-asset price from a DIA feed (keyed
  by bare symbol, e.g. `"COIN"`) and multiplies by the vault's
  `totalAssets / totalSupply`; 8-decimal `AggregatorV2V3Interface`.
- **PausableOracleWrapper** — shape-preserving decorator over any
  `AggregatorV2V3Interface`: manual admin pause + automatic corporate-action
  pause via `LibCorporateActionsPause`. The wrapper proxy is the canonical
  consumer-facing address; its upstream is immutable.
- **DIAVaultOracleBeaconSetDeployer / PausableOracleWrapperBeaconSetDeployer** —
  each owns an `UpgradeableBeacon` and mints beacon proxies of its
  implementation.
- **DIAOracleUnifiedDeployer** — atomic (oracle, wrapper) pair deploy with the
  wrapper's upstream wired to the fresh adapter.

**Signed-price stack** (Morpho Blue markets):

- **ST0xPriceOracle** — singleton multi-pair price store behind a beacon proxy.
  Permissionless `updatePrice` authorised by the global publisher's EIP-712
  signature; strict per-pair timestamp inequality is the replay defence.
  `ORACLE_ADMIN_ROLE` rotates signer/timeout.
- **MorphoPairOracle** — thin beacon-proxied adapter exposing one pair on the
  central store through Morpho Blue's `IOracle.price()`.

Beacon pattern throughout: implementations are deployed once and proxied; one
beacon upgrade retargets every proxy minted from it.
