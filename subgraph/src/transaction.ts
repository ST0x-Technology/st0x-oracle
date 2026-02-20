import { ethereum, Bytes } from "@graphprotocol/graph-ts";
import { Transaction } from "../generated/schema";

export function createTransactionEntity(event: ethereum.Event): Transaction {
  let tx = Transaction.load(event.transaction.hash);
  if (tx == null) {
    tx = new Transaction(event.transaction.hash);
    tx.timestamp = event.block.timestamp;
    tx.blockNumber = event.block.number;
    tx.from = event.transaction.from;
    tx.save();
  }
  return tx;
}

export function eventId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32());
}
