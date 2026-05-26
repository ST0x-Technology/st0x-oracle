import {
  PythOracleAdapterInitialized,
  PauseSet as PythPauseSet,
  AdminSet as PythAdminSet,
} from "../generated/templates/PythOracleAdapterTemplate/PythOracleAdapter";
import {
  PythOracleAdapter,
  PauseEvent,
  AdapterAdminChange,
} from "../generated/schema";
import { createTransactionEntity, eventId } from "./transaction";

// --- Single Pyth ---

export function handlePythOracleAdapterInitialized(
  event: PythOracleAdapterInitialized
): void {
  createTransactionEntity(event);

  let adapter = new PythOracleAdapter(event.address);
  adapter.vault = event.params.config.vault;
  adapter.priceId = event.params.config.priceId;
  adapter.maxAge = event.params.config.maxAge;
  adapter.admin = event.params.config.admin;
  adapter.isPaused = false;
  adapter.createdAt = event.block.timestamp;
  adapter.createdTransaction = event.transaction.hash;
  adapter.save();
}

export function handlePauseSet(event: PythPauseSet): void {
  createTransactionEntity(event);

  let adapter = PythOracleAdapter.load(event.address);
  if (adapter != null) {
    adapter.isPaused = event.params.isPaused;
    adapter.save();
  }

  let pause = new PauseEvent(eventId(event));
  pause.adapter = event.address;
  pause.isPaused = event.params.isPaused;
  pause.timestamp = event.block.timestamp;
  pause.transaction = event.transaction.hash;
  pause.save();
}

export function handleAdapterAdminSet(event: PythAdminSet): void {
  createTransactionEntity(event);

  let adapter = PythOracleAdapter.load(event.address);
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
