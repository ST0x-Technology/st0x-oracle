import { Deployment as RegistryDeployment } from "../generated/OracleRegistryBeaconSetDeployer/OracleRegistryBeaconSetDeployer";
import { Deployment as PythAdapterDeployment } from "../generated/PythOracleAdapterBeaconSetDeployer/PythOracleAdapterBeaconSetDeployer";
import { Deployment as MultiPythAdapterDeployment } from "../generated/MultiPythOracleAdapterBeaconSetDeployer/MultiPythOracleAdapterBeaconSetDeployer";
import { Deployment as MorphoAdapterDeployment } from "../generated/MorphoProtocolAdapterBeaconSetDeployer/MorphoProtocolAdapterBeaconSetDeployer";
import { Deployment as PassthroughAdapterDeployment } from "../generated/PassthroughProtocolAdapterBeaconSetDeployer/PassthroughProtocolAdapterBeaconSetDeployer";
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

// --- Beacon Set Deployers (individual) ---

export function handleRegistryDeployment(event: RegistryDeployment): void {
  createTransactionEntity(event);
  OracleRegistryTemplate.create(event.params.oracleRegistry);
}

export function handlePythAdapterDeployment(
  event: PythAdapterDeployment
): void {
  createTransactionEntity(event);
  PythOracleAdapterTemplate.create(event.params.pythOracleAdapter);
}

export function handleMultiPythAdapterDeployment(
  event: MultiPythAdapterDeployment
): void {
  createTransactionEntity(event);
  MultiPythOracleAdapterTemplate.create(
    event.params.multiPythOracleAdapter
  );
}

export function handleMorphoAdapterDeployment(
  event: MorphoAdapterDeployment
): void {
  createTransactionEntity(event);
  MorphoProtocolAdapterTemplate.create(event.params.morphoProtocolAdapter);
}

export function handlePassthroughAdapterDeployment(
  event: PassthroughAdapterDeployment
): void {
  createTransactionEntity(event);
  PassthroughProtocolAdapterTemplate.create(
    event.params.passthroughProtocolAdapter
  );
}

// --- Unified Deployers (oracle + morpho + passthrough in one tx) ---

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
