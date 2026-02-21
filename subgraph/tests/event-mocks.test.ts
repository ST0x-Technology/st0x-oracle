import { newMockEvent } from "matchstick-as";
import { ethereum, Address, Bytes, BigInt } from "@graphprotocol/graph-ts";
import {
  OracleRegistryInitialized,
  OracleSet,
  AdminSet,
} from "../generated/OracleRegistry/OracleRegistry";
import { Deployment as SingleDeploymentEvent } from "../generated/OracleUnifiedDeployer/OracleUnifiedDeployer";
import { Deployment as MultiDeploymentEvent } from "../generated/MultiOracleUnifiedDeployer/MultiOracleUnifiedDeployer";
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
  MorphoProtocolAdapterInitialized,
  AdminSet as MorphoAdminSet,
  RegistrySet as MorphoRegistrySet,
} from "../generated/templates/MorphoProtocolAdapterTemplate/MorphoProtocolAdapter";
import {
  PassthroughProtocolAdapterInitialized,
  AdminSet as PassthroughAdminSet,
  RegistrySet as PassthroughRegistrySet,
} from "../generated/templates/PassthroughProtocolAdapterTemplate/PassthroughProtocolAdapter";

// --- Registry ---

export function createOracleRegistryInitializedEvent(
  sender: Address,
  admin: Address
): OracleRegistryInitialized {
  let mockEvent = newMockEvent();
  let event = new OracleRegistryInitialized(
    mockEvent.address,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );
  // config is a tuple with one field: admin
  let configTuple = new ethereum.Tuple();
  configTuple.push(ethereum.Value.fromAddress(admin));
  event.parameters.push(
    new ethereum.EventParam("config", ethereum.Value.fromTuple(configTuple))
  );
  return event;
}

export function createOracleSetEvent(
  vault: Address,
  oldOracle: Address,
  newOracle: Address
): OracleSet {
  let mockEvent = newMockEvent();
  let event = new OracleSet(
    mockEvent.address,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("vault", ethereum.Value.fromAddress(vault))
  );
  event.parameters.push(
    new ethereum.EventParam("oldOracle", ethereum.Value.fromAddress(oldOracle))
  );
  event.parameters.push(
    new ethereum.EventParam("newOracle", ethereum.Value.fromAddress(newOracle))
  );
  return event;
}

export function createAdminSetEvent(
  oldAdmin: Address,
  newAdmin: Address
): AdminSet {
  let mockEvent = newMockEvent();
  let event = new AdminSet(
    mockEvent.address,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("oldAdmin", ethereum.Value.fromAddress(oldAdmin))
  );
  event.parameters.push(
    new ethereum.EventParam("newAdmin", ethereum.Value.fromAddress(newAdmin))
  );
  return event;
}

// --- Deployers ---

export function createSingleDeploymentEvent(
  sender: Address,
  pythOracleAdapter: Address,
  morphoProtocolAdapter: Address,
  passthroughProtocolAdapter: Address
): SingleDeploymentEvent {
  let mockEvent = newMockEvent();
  let event = new SingleDeploymentEvent(
    mockEvent.address,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );
  event.parameters.push(
    new ethereum.EventParam(
      "pythOracleAdapter",
      ethereum.Value.fromAddress(pythOracleAdapter)
    )
  );
  event.parameters.push(
    new ethereum.EventParam(
      "morphoProtocolAdapter",
      ethereum.Value.fromAddress(morphoProtocolAdapter)
    )
  );
  event.parameters.push(
    new ethereum.EventParam(
      "passthroughProtocolAdapter",
      ethereum.Value.fromAddress(passthroughProtocolAdapter)
    )
  );
  return event;
}

export function createMultiDeploymentEvent(
  sender: Address,
  multiPythOracleAdapter: Address,
  morphoProtocolAdapter: Address,
  passthroughProtocolAdapter: Address
): MultiDeploymentEvent {
  let mockEvent = newMockEvent();
  let event = new MultiDeploymentEvent(
    mockEvent.address,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );
  event.parameters.push(
    new ethereum.EventParam(
      "multiPythOracleAdapter",
      ethereum.Value.fromAddress(multiPythOracleAdapter)
    )
  );
  event.parameters.push(
    new ethereum.EventParam(
      "morphoProtocolAdapter",
      ethereum.Value.fromAddress(morphoProtocolAdapter)
    )
  );
  event.parameters.push(
    new ethereum.EventParam(
      "passthroughProtocolAdapter",
      ethereum.Value.fromAddress(passthroughProtocolAdapter)
    )
  );
  return event;
}

// --- Single Pyth Oracle Adapter ---

export function createPythOracleAdapterInitializedEvent(
  contractAddress: Address,
  sender: Address,
  vault: Address,
  priceId: Bytes,
  maxAge: BigInt,
  admin: Address
): PythOracleAdapterInitialized {
  let mockEvent = newMockEvent();
  let event = new PythOracleAdapterInitialized(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );
  let configTuple = new ethereum.Tuple();
  configTuple.push(ethereum.Value.fromAddress(vault));
  configTuple.push(ethereum.Value.fromFixedBytes(priceId));
  configTuple.push(ethereum.Value.fromUnsignedBigInt(maxAge));
  configTuple.push(ethereum.Value.fromAddress(admin));
  event.parameters.push(
    new ethereum.EventParam("config", ethereum.Value.fromTuple(configTuple))
  );
  return event;
}

export function createPythPauseSetEvent(
  contractAddress: Address,
  isPaused: boolean
): PythPauseSet {
  let mockEvent = newMockEvent();
  let event = new PythPauseSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("isPaused", ethereum.Value.fromBoolean(isPaused))
  );
  return event;
}

export function createPythAdminSetEvent(
  contractAddress: Address,
  oldAdmin: Address,
  newAdmin: Address
): PythAdminSet {
  let mockEvent = newMockEvent();
  let event = new PythAdminSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("oldAdmin", ethereum.Value.fromAddress(oldAdmin))
  );
  event.parameters.push(
    new ethereum.EventParam("newAdmin", ethereum.Value.fromAddress(newAdmin))
  );
  return event;
}

// --- Multi Pyth Oracle Adapter ---

export function createMultiPythOracleAdapterInitializedEvent(
  contractAddress: Address,
  sender: Address,
  vault: Address,
  feedPriceIds: Bytes[],
  feedMaxAges: BigInt[],
  admin: Address
): MultiPythOracleAdapterInitialized {
  let mockEvent = newMockEvent();
  let event = new MultiPythOracleAdapterInitialized(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );

  let feedTuples = new Array<ethereum.Value>();
  for (let i = 0; i < feedPriceIds.length; i++) {
    let feedTuple = new ethereum.Tuple();
    feedTuple.push(ethereum.Value.fromFixedBytes(feedPriceIds[i]));
    feedTuple.push(ethereum.Value.fromUnsignedBigInt(feedMaxAges[i]));
    feedTuples.push(ethereum.Value.fromTuple(feedTuple));
  }

  let configTuple = new ethereum.Tuple();
  configTuple.push(ethereum.Value.fromAddress(vault));
  configTuple.push(ethereum.Value.fromArray(feedTuples));
  configTuple.push(ethereum.Value.fromAddress(admin));
  event.parameters.push(
    new ethereum.EventParam("config", ethereum.Value.fromTuple(configTuple))
  );
  return event;
}

export function createFeedsSetEvent(
  contractAddress: Address,
  feedPriceIds: Bytes[],
  feedMaxAges: BigInt[]
): FeedsSet {
  let mockEvent = newMockEvent();
  let event = new FeedsSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();

  let feedTuples = new Array<ethereum.Value>();
  for (let i = 0; i < feedPriceIds.length; i++) {
    let feedTuple = new ethereum.Tuple();
    feedTuple.push(ethereum.Value.fromFixedBytes(feedPriceIds[i]));
    feedTuple.push(ethereum.Value.fromUnsignedBigInt(feedMaxAges[i]));
    feedTuples.push(ethereum.Value.fromTuple(feedTuple));
  }
  event.parameters.push(
    new ethereum.EventParam("feeds", ethereum.Value.fromArray(feedTuples))
  );
  return event;
}

export function createFeedMaxAgeSetEvent(
  contractAddress: Address,
  index: BigInt,
  maxAge: BigInt
): FeedMaxAgeSet {
  let mockEvent = newMockEvent();
  let event = new FeedMaxAgeSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("index", ethereum.Value.fromUnsignedBigInt(index))
  );
  event.parameters.push(
    new ethereum.EventParam("maxAge", ethereum.Value.fromUnsignedBigInt(maxAge))
  );
  return event;
}

export function createMultiPauseSetEvent(
  contractAddress: Address,
  isPaused: boolean
): MultiPauseSet {
  let mockEvent = newMockEvent();
  let event = new MultiPauseSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("isPaused", ethereum.Value.fromBoolean(isPaused))
  );
  return event;
}

export function createMultiAdminSetEvent(
  contractAddress: Address,
  oldAdmin: Address,
  newAdmin: Address
): MultiAdminSet {
  let mockEvent = newMockEvent();
  let event = new MultiAdminSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("oldAdmin", ethereum.Value.fromAddress(oldAdmin))
  );
  event.parameters.push(
    new ethereum.EventParam("newAdmin", ethereum.Value.fromAddress(newAdmin))
  );
  return event;
}

// --- Morpho Protocol Adapter ---

export function createMorphoInitializedEvent(
  contractAddress: Address,
  sender: Address,
  registry: Address,
  vault: Address,
  admin: Address
): MorphoProtocolAdapterInitialized {
  let mockEvent = newMockEvent();
  let event = new MorphoProtocolAdapterInitialized(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );
  let configTuple = new ethereum.Tuple();
  configTuple.push(ethereum.Value.fromAddress(registry));
  configTuple.push(ethereum.Value.fromAddress(vault));
  configTuple.push(ethereum.Value.fromAddress(admin));
  event.parameters.push(
    new ethereum.EventParam("config", ethereum.Value.fromTuple(configTuple))
  );
  return event;
}

export function createMorphoAdminSetEvent(
  contractAddress: Address,
  oldAdmin: Address,
  newAdmin: Address
): MorphoAdminSet {
  let mockEvent = newMockEvent();
  let event = new MorphoAdminSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("oldAdmin", ethereum.Value.fromAddress(oldAdmin))
  );
  event.parameters.push(
    new ethereum.EventParam("newAdmin", ethereum.Value.fromAddress(newAdmin))
  );
  return event;
}

export function createMorphoRegistrySetEvent(
  contractAddress: Address,
  oldRegistry: Address,
  newRegistry: Address
): MorphoRegistrySet {
  let mockEvent = newMockEvent();
  let event = new MorphoRegistrySet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam(
      "oldRegistry",
      ethereum.Value.fromAddress(oldRegistry)
    )
  );
  event.parameters.push(
    new ethereum.EventParam(
      "newRegistry",
      ethereum.Value.fromAddress(newRegistry)
    )
  );
  return event;
}

// --- Passthrough Protocol Adapter ---

export function createPassthroughInitializedEvent(
  contractAddress: Address,
  sender: Address,
  registry: Address,
  vault: Address,
  admin: Address
): PassthroughProtocolAdapterInitialized {
  let mockEvent = newMockEvent();
  let event = new PassthroughProtocolAdapterInitialized(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  );
  let configTuple = new ethereum.Tuple();
  configTuple.push(ethereum.Value.fromAddress(registry));
  configTuple.push(ethereum.Value.fromAddress(vault));
  configTuple.push(ethereum.Value.fromAddress(admin));
  event.parameters.push(
    new ethereum.EventParam("config", ethereum.Value.fromTuple(configTuple))
  );
  return event;
}

export function createPassthroughAdminSetEvent(
  contractAddress: Address,
  oldAdmin: Address,
  newAdmin: Address
): PassthroughAdminSet {
  let mockEvent = newMockEvent();
  let event = new PassthroughAdminSet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam("oldAdmin", ethereum.Value.fromAddress(oldAdmin))
  );
  event.parameters.push(
    new ethereum.EventParam("newAdmin", ethereum.Value.fromAddress(newAdmin))
  );
  return event;
}

export function createPassthroughRegistrySetEvent(
  contractAddress: Address,
  oldRegistry: Address,
  newRegistry: Address
): PassthroughRegistrySet {
  let mockEvent = newMockEvent();
  let event = new PassthroughRegistrySet(
    contractAddress,
    mockEvent.logIndex,
    mockEvent.transactionLogIndex,
    mockEvent.logType,
    mockEvent.block,
    mockEvent.transaction,
    mockEvent.parameters,
    null
  );
  event.parameters = new Array();
  event.parameters.push(
    new ethereum.EventParam(
      "oldRegistry",
      ethereum.Value.fromAddress(oldRegistry)
    )
  );
  event.parameters.push(
    new ethereum.EventParam(
      "newRegistry",
      ethereum.Value.fromAddress(newRegistry)
    )
  );
  return event;
}
