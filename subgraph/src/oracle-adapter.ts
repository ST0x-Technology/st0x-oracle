import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  PythOracleAdapterInitialized,
  PauseSet as PythPauseSet,
  AdminSet as PythAdminSet,
} from "../generated/templates/PythOracleAdapterTemplate/PythOracleAdapter";
import {
  MultiPythOracleAdapterInitialized,
  FeedsSet,
  FeedMaxAgeSet,
  PauseSet as MultiPauseSet,
  AdminSet as MultiAdminSet,
} from "../generated/templates/MultiPythOracleAdapterTemplate/MultiPythOracleAdapter";
import {
  PythOracleAdapter,
  MultiPythOracleAdapter,
  FeedConfig,
  PauseEvent,
  AdapterAdminChange,
} from "../generated/schema";
import { createTransactionEntity, eventId } from "./transaction";

function feedConfigId(adapter: Bytes, index: BigInt): Bytes {
  return adapter.concatI32(index.toI32());
}

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

// --- Multi Pyth ---

export function handleMultiPythOracleAdapterInitialized(
  event: MultiPythOracleAdapterInitialized
): void {
  createTransactionEntity(event);

  let adapter = new MultiPythOracleAdapter(event.address);
  adapter.vault = event.params.config.vault;
  adapter.admin = event.params.config.admin;
  adapter.isPaused = false;
  adapter.feedCount = BigInt.fromI32(event.params.config.feeds.length);
  adapter.createdAt = event.block.timestamp;
  adapter.createdTransaction = event.transaction.hash;
  adapter.save();

  let feeds = event.params.config.feeds;
  for (let i = 0; i < feeds.length; i++) {
    let idx = BigInt.fromI32(i);
    let feed = new FeedConfig(feedConfigId(event.address, idx));
    feed.adapter = event.address;
    feed.index = idx;
    feed.priceId = feeds[i].priceId;
    feed.maxAge = feeds[i].maxAge;
    feed.save();
  }
}

export function handleFeedsSet(event: FeedsSet): void {
  createTransactionEntity(event);

  let adapter = MultiPythOracleAdapter.load(event.address);
  if (adapter == null) return;

  // Remove old feed configs
  let oldCount = adapter.feedCount.toI32();
  for (let i = 0; i < oldCount; i++) {
    let id = feedConfigId(event.address, BigInt.fromI32(i));
    let old = FeedConfig.load(id);
    // Can't delete in subgraphs, but we'll overwrite below
  }

  let feeds = event.params.feeds;
  adapter.feedCount = BigInt.fromI32(feeds.length);
  adapter.save();

  for (let i = 0; i < feeds.length; i++) {
    let idx = BigInt.fromI32(i);
    let feed = new FeedConfig(feedConfigId(event.address, idx));
    feed.adapter = event.address;
    feed.index = idx;
    feed.priceId = feeds[i].priceId;
    feed.maxAge = feeds[i].maxAge;
    feed.save();
  }
}

export function handleFeedMaxAgeSet(event: FeedMaxAgeSet): void {
  createTransactionEntity(event);

  let idx = BigInt.fromI32(event.params.index.toI32());
  let id = feedConfigId(event.address, idx);
  let feed = FeedConfig.load(id);
  if (feed != null) {
    feed.maxAge = event.params.maxAge;
    feed.save();
  }
}

export function handleMultiPauseSet(event: MultiPauseSet): void {
  createTransactionEntity(event);

  let adapter = MultiPythOracleAdapter.load(event.address);
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

export function handleMultiAdapterAdminSet(event: MultiAdminSet): void {
  createTransactionEntity(event);

  let adapter = MultiPythOracleAdapter.load(event.address);
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
