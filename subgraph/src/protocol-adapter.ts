import {
  MorphoProtocolAdapterInitialized,
  AdminSet as MorphoAdminSet,
  RegistrySet as MorphoRegistrySet,
} from "../generated/templates/MorphoProtocolAdapterTemplate/MorphoProtocolAdapter";
import {
  PassthroughProtocolAdapterInitialized,
  AdminSet as PassthroughAdminSet,
  RegistrySet as PassthroughRegistrySet,
} from "../generated/templates/PassthroughProtocolAdapterTemplate/PassthroughProtocolAdapter";
import {
  MorphoProtocolAdapter,
  PassthroughProtocolAdapter,
  AdapterAdminChange,
  RegistryChange,
} from "../generated/schema";
import { createTransactionEntity, eventId } from "./transaction";

// --- Morpho ---

export function handleMorphoInitialized(
  event: MorphoProtocolAdapterInitialized
): void {
  createTransactionEntity(event);

  let adapter = new MorphoProtocolAdapter(event.address);
  adapter.vault = event.params.config.vault;
  adapter.registry = event.params.config.registry;
  adapter.admin = event.params.config.admin;
  adapter.createdAt = event.block.timestamp;
  adapter.createdTransaction = event.transaction.hash;
  adapter.save();
}

export function handleMorphoAdminSet(event: MorphoAdminSet): void {
  createTransactionEntity(event);

  let adapter = MorphoProtocolAdapter.load(event.address);
  if (adapter != null) {
    adapter.admin = event.params.newAdmin;
    adapter.save();
  }

  let change = new AdapterAdminChange(eventId(event));
  change.contract = event.address;
  change.oldAdmin = event.params.oldAdmin;
  change.newAdmin = event.params.newAdmin;
  change.timestamp = event.block.timestamp;
  change.transaction = event.transaction.hash;
  change.save();
}

export function handleMorphoRegistrySet(event: MorphoRegistrySet): void {
  createTransactionEntity(event);

  let adapter = MorphoProtocolAdapter.load(event.address);
  if (adapter != null) {
    adapter.registry = event.params.newRegistry;
    adapter.save();
  }

  let change = new RegistryChange(eventId(event));
  change.adapter = event.address;
  change.oldRegistry = event.params.oldRegistry;
  change.newRegistry = event.params.newRegistry;
  change.timestamp = event.block.timestamp;
  change.transaction = event.transaction.hash;
  change.save();
}

// --- Passthrough ---

export function handlePassthroughInitialized(
  event: PassthroughProtocolAdapterInitialized
): void {
  createTransactionEntity(event);

  let adapter = new PassthroughProtocolAdapter(event.address);
  adapter.vault = event.params.config.vault;
  adapter.registry = event.params.config.registry;
  adapter.admin = event.params.config.admin;
  adapter.createdAt = event.block.timestamp;
  adapter.createdTransaction = event.transaction.hash;
  adapter.save();
}

export function handlePassthroughAdminSet(event: PassthroughAdminSet): void {
  createTransactionEntity(event);

  let adapter = PassthroughProtocolAdapter.load(event.address);
  if (adapter != null) {
    adapter.admin = event.params.newAdmin;
    adapter.save();
  }

  let change = new AdapterAdminChange(eventId(event));
  change.contract = event.address;
  change.oldAdmin = event.params.oldAdmin;
  change.newAdmin = event.params.newAdmin;
  change.timestamp = event.block.timestamp;
  change.transaction = event.transaction.hash;
  change.save();
}

export function handlePassthroughRegistrySet(
  event: PassthroughRegistrySet
): void {
  createTransactionEntity(event);

  let adapter = PassthroughProtocolAdapter.load(event.address);
  if (adapter != null) {
    adapter.registry = event.params.newRegistry;
    adapter.save();
  }

  let change = new RegistryChange(eventId(event));
  change.adapter = event.address;
  change.oldRegistry = event.params.oldRegistry;
  change.newRegistry = event.params.newRegistry;
  change.timestamp = event.block.timestamp;
  change.transaction = event.transaction.hash;
  change.save();
}
