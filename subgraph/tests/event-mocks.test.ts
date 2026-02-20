import { newMockEvent } from "matchstick-as";
import { ethereum, Address, Bytes } from "@graphprotocol/graph-ts";
import {
  OracleSet,
  AdminSet,
} from "../generated/OracleRegistry/OracleRegistry";
import { createTransactionEntity } from "../src/transaction";

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

  createTransactionEntity(event);
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

  createTransactionEntity(event);
  return event;
}
