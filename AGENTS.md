# AGENTS.md — st0x.oracle

## Tooling

Nix flakes only — never globally installed `forge`/`solc`: `nix develop` (or
`nix develop -c <cmd>`). Fresh clone: `dependencies/` is gitignored — run
`forge soldeer install` first.

## Before pushing — mirror every CI gate locally

`forge fmt --check` · `forge test -vvv` · `slither .` ·
`rainix-sol-single-contract` · `reuse lint`. Never push to find out from CI.

Org gates with no local task: no git submodules (soldeer only); no `@custom:`
NatSpec except the exact ERC-7201 `@custom:storage-location`; no ignored/skipped
tests — a test runs and passes or is deleted.

Slither false positives: `// slither-disable-next-line <detector>` plus a
comment explaining WHY it is false.

## Fork tests

`vm.createSelectFork("base")` via the `foundry.toml` `[rpc_endpoints]` alias —
never a raw env read. Referencing a network there is what opts it into CI's
rpc-preflight probe; add the alias before adding fork tests for a new chain.
Locally: `export BASE_RPC_URL=https://mainnet.base.org` before `forge test`.

## Deployment

Via `manual-sol-artifacts.yaml` only (runs `script/Deploy.sol` with a
`DEPLOYMENT_SUITE`), never locally. Deployed addresses are kept as `.sol`
constants, not a separate registry file.

- `BEACON_INITIAL_OWNER` and the `st0x-*` role inputs must each differ from the
  deploy key — beacon owner and signer control every served price, so they are
  governance, never the hot CI key. `Deploy.sol` enforces this; do not weaken
  it.
- **Hazard:** a missing `CI_DEPLOY_<NETWORK>_<SUFFIX>` secret resolves to empty
  and the deploy proceeds UNVERIFIED instead of erroring — confirm all five
  suffixes (`RPC_URL`, `ETHERSCAN_API_KEY`, `VERIFY`, `VERIFIER`,
  `VERIFIER_URL`) exist before dispatching a non-`base` network. Verifier URL is
  etherscan v2 with the chain id:
  `https://api.etherscan.io/v2/api?chainid=<id>`.
- The signing key is not per-network: `secrets.PRIVATE_KEY` for runs from
  `main`, `secrets.PRIVATE_KEY_DEV` from any other ref.

## Toolchain pins — two by design

CI runs the reusable rainix workflows at `@main` (org convention: a rainix CI
fix propagates instantly); local dev + `manual-sol-artifacts.yaml` use this
repo's `flake.lock`. They are ALLOWED to differ — do not add a sync check.
`nix flake update` when local tooling needs to catch up.
