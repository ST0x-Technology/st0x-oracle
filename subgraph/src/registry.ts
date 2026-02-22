import { Bytes } from "@graphprotocol/graph-ts";
import {
  OracleRegistryInitialized,
  OracleSet,
  AdminSet,
} from "../generated/templates/OracleRegistryTemplate/OracleRegistry";
import {
  OracleRegistry,
  OracleMapping,
  OracleChange,
  RegistryAdminChange,
} from "../generated/schema";
import { createTransactionEntity, eventId } from "./transaction";

function oracleMappingId(registry: Bytes, vault: Bytes): Bytes {
  return registry.concat(vault);
}

export function handleOracleRegistryInitialized(
  event: OracleRegistryInitialized
): void {
  createTransactionEntity(event);

  let registry = new OracleRegistry(event.address);
  registry.admin = event.params.sender;
  registry.save();
}

export function handleOracleSet(event: OracleSet): void {
  createTransactionEntity(event);

  let mappingId = oracleMappingId(event.address, event.params.vault);
  let mapping = OracleMapping.load(mappingId);
  if (mapping == null) {
    mapping = new OracleMapping(mappingId);
    mapping.registry = event.address;
    mapping.vault = event.params.vault;
  }
  mapping.oracle = event.params.newOracle;
  mapping.save();

  let change = new OracleChange(eventId(event));
  change.mapping = mappingId;
  change.vault = event.params.vault;
  change.oldOracle = event.params.oldOracle;
  change.newOracle = event.params.newOracle;
  change.timestamp = event.block.timestamp;
  change.transaction = event.transaction.hash;
  change.save();
}

export function handleRegistryAdminSet(event: AdminSet): void {
  createTransactionEntity(event);

  let registry = OracleRegistry.load(event.address);
  if (registry != null) {
    registry.admin = event.params.newAdmin;
    registry.save();
  }

  let change = new RegistryAdminChange(eventId(event));
  change.registry = event.address;
  change.oldAdmin = event.params.oldAdmin;
  change.newAdmin = event.params.newAdmin;
  change.timestamp = event.block.timestamp;
  change.transaction = event.transaction.hash;
  change.save();
}
