# st0x.oracle subgraph

The Graph subgraph that indexes deployment events from the `BeaconSetDeployer`
contracts and the `OracleRegistry`. Driven by `subgraph.yaml` and the network
address book in `networks.json`.

## Address duplication with `src/lib/LibProdDeploy.sol`

> **Heads up.** `subgraph/networks.json` duplicates every deployer address
> from `src/lib/LibProdDeploy.sol` (Solidity constants). The two files are
> currently kept in sync **by hand** as part of the deployment-PR ritual
> documented in `AGENTS.md` § Deployment.
>
> Concretely, every `LibProdDeploy.*_BEACON_SET_DEPLOYER` /
> `LibProdDeploy.*_UNIFIED_DEPLOYER` / `LibProdDeploy.ORACLE_REGISTRY*`
> address has a mirror entry under `base.<ContractName>.address` in
> `networks.json`. If the two ever diverge, the subgraph indexes a
> different deployment than the contracts ship against.
>
> Drift risks are the same ones called out in `AGENTS.md`: typo on copy,
> paste into the wrong key, PR merged out of order. The gen-pipeline
> overhaul that would replace this hand-maintenance with a JSON artifact
> emitted by the deployment workflow is tracked at **#220** (parent: the
> broader deployment-pipeline rework at #210).

## Local development

```bash
cd subgraph
npm install
npm run codegen
npm run build
npm run test       # matchstick unit tests
```

`docker-compose.yml` brings up a local graph-node + ipfs + postgres for
end-to-end smoke testing. See `package.json` for the full script list.
