import { Address } from "@graphprotocol/graph-ts";
import { Deployment as RegistryDeployment } from "../generated/OracleRegistryBeaconSetDeployer/OracleRegistryBeaconSetDeployer";
import { Deployment as SingleDeployment } from "../generated/OracleUnifiedDeployer/OracleUnifiedDeployer";
import { Deployment as MultiDeployment } from "../generated/MultiOracleUnifiedDeployer/MultiOracleUnifiedDeployer";
import { UnifiedDeployment } from "../generated/schema";
import {
  OracleRegistryTemplate,
  PythOracleAdapterTemplate,
  MultiPythOracleAdapterTemplate,
  MorphoProtocolAdapterTemplate,
  PassthroughProtocolAdapterTemplate,
} from "../generated/templates";
import { createTransactionEntity, eventId } from "./transaction";

export function handleRegistryDeployment(event: RegistryDeployment): void {
  createTransactionEntity(event);
  OracleRegistryTemplate.create(event.params.oracleRegistry);
}

export function handleSingleDeployment(event: SingleDeployment): void {
  createTransactionEntity(event);

  let deployment = new UnifiedDeployment(eventId(event));
  deployment.kind = "single";
  deployment.sender = event.params.sender;
  deployment.oracleAdapter = event.params.pythOracleAdapter;
  deployment.morphoAdapter = event.params.morphoProtocolAdapter;
  deployment.passthroughAdapter = event.params.passthroughProtocolAdapter;
  deployment.timestamp = event.block.timestamp;
  deployment.transaction = event.transaction.hash;
  deployment.save();

  // Create dynamic data sources for the new adapters
  PythOracleAdapterTemplate.create(event.params.pythOracleAdapter);
  MorphoProtocolAdapterTemplate.create(event.params.morphoProtocolAdapter);
  PassthroughProtocolAdapterTemplate.create(
    event.params.passthroughProtocolAdapter
  );
}

export function handleMultiDeployment(event: MultiDeployment): void {
  createTransactionEntity(event);

  let deployment = new UnifiedDeployment(eventId(event));
  deployment.kind = "multi";
  deployment.sender = event.params.sender;
  deployment.oracleAdapter = event.params.multiPythOracleAdapter;
  deployment.morphoAdapter = event.params.morphoProtocolAdapter;
  deployment.passthroughAdapter = event.params.passthroughProtocolAdapter;
  deployment.timestamp = event.block.timestamp;
  deployment.transaction = event.transaction.hash;
  deployment.save();

  // Create dynamic data sources for the new adapters
  MultiPythOracleAdapterTemplate.create(event.params.multiPythOracleAdapter);
  MorphoProtocolAdapterTemplate.create(event.params.morphoProtocolAdapter);
  PassthroughProtocolAdapterTemplate.create(
    event.params.passthroughProtocolAdapter
  );
}
