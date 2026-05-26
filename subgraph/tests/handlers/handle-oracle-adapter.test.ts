import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address, Bytes, BigInt } from "@graphprotocol/graph-ts";
import {
  createPythOracleAdapterInitializedEvent,
  createPythPauseSetEvent,
  createPythAdminSetEvent,
} from "../event-mocks.test";
import {
  handlePythOracleAdapterInitialized,
  handlePauseSet,
  handleAdapterAdminSet,
} from "../../src/oracle-adapter";
import { PythOracleAdapter } from "../../generated/schema";

let ADAPTER = Address.fromString(
  "0x1C63889a9FAd36C6a4422B3dAFCD57b11deC73d8"
);
let SENDER = Address.fromString(
  "0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b"
);
let VAULT = Address.fromString(
  "0x5cDa0E1CA4ce2af96315f7F8963C85399c172204"
);
let ADMIN = Address.fromString(
  "0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b"
);
let NEW_ADMIN = Address.fromString(
  "0x1111111111111111111111111111111111111111"
);
let PRICE_ID = Bytes.fromHexString(
  "0xfee3000000000000000000000000000000000000000000000000000000000000"
);
let PRICE_ID_2 = Bytes.fromHexString(
  "0x8bde000000000000000000000000000000000000000000000000000000000000"
);
let PRICE_ID_3 = Bytes.fromHexString(
  "0x5c3b000000000000000000000000000000000000000000000000000000000000"
);

// --- Single Pyth ---

describe("handlePythOracleAdapterInitialized", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates PythOracleAdapter with all fields", () => {
    let maxAge = BigInt.fromI32(300);
    let event = createPythOracleAdapterInitializedEvent(
      ADAPTER,
      SENDER,
      VAULT,
      PRICE_ID,
      maxAge,
      ADMIN
    );
    handlePythOracleAdapterInitialized(event);

    assert.entityCount("PythOracleAdapter", 1);
    let id = ADAPTER.toHexString();
    assert.fieldEquals("PythOracleAdapter", id, "vault", VAULT.toHexString());
    assert.fieldEquals(
      "PythOracleAdapter",
      id,
      "priceId",
      PRICE_ID.toHexString()
    );
    assert.fieldEquals("PythOracleAdapter", id, "maxAge", "300");
    assert.fieldEquals("PythOracleAdapter", id, "admin", ADMIN.toHexString());
    assert.fieldEquals("PythOracleAdapter", id, "isPaused", "false");
    assert.entityCount("Transaction", 1);
  });
});

describe("handlePauseSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("pauses adapter and creates PauseEvent", () => {
    // Pre-create adapter
    let adapter = new PythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.priceId = PRICE_ID;
    adapter.maxAge = BigInt.fromI32(300);
    adapter.admin = ADMIN;
    adapter.isPaused = false;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createPythPauseSetEvent(ADAPTER, true);
    handlePauseSet(event);

    assert.fieldEquals(
      "PythOracleAdapter",
      ADAPTER.toHexString(),
      "isPaused",
      "true"
    );
    assert.entityCount("PauseEvent", 1);

    let pauseId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "PauseEvent",
      pauseId,
      "adapter",
      ADAPTER.toHexString()
    );
    assert.fieldEquals("PauseEvent", pauseId, "isPaused", "true");
  });

  test("unpauses adapter", () => {
    let adapter = new PythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.priceId = PRICE_ID;
    adapter.maxAge = BigInt.fromI32(300);
    adapter.admin = ADMIN;
    adapter.isPaused = true;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createPythPauseSetEvent(ADAPTER, false);
    handlePauseSet(event);

    assert.fieldEquals(
      "PythOracleAdapter",
      ADAPTER.toHexString(),
      "isPaused",
      "false"
    );
  });
});

describe("handleAdapterAdminSet (single pyth)", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates adapter admin and creates AdapterAdminChange", () => {
    let adapter = new PythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.priceId = PRICE_ID;
    adapter.maxAge = BigInt.fromI32(300);
    adapter.admin = ADMIN;
    adapter.isPaused = false;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createPythAdminSetEvent(ADAPTER, ADMIN, NEW_ADMIN);
    handleAdapterAdminSet(event);

    assert.fieldEquals(
      "PythOracleAdapter",
      ADAPTER.toHexString(),
      "admin",
      NEW_ADMIN.toHexString()
    );
    assert.entityCount("AdapterAdminChange", 1);

    let changeId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "AdapterAdminChange",
      changeId,
      "contract",
      ADAPTER.toHexString()
    );
    assert.fieldEquals(
      "AdapterAdminChange",
      changeId,
      "oldAdmin",
      ADMIN.toHexString()
    );
    assert.fieldEquals(
      "AdapterAdminChange",
      changeId,
      "newAdmin",
      NEW_ADMIN.toHexString()
    );
  });
});
