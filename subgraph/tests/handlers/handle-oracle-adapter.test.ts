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
  createMultiPythOracleAdapterInitializedEvent,
  createFeedsSetEvent,
  createFeedMaxAgeSetEvent,
  createMultiPauseSetEvent,
  createMultiAdminSetEvent,
} from "../event-mocks.test";
import {
  handlePythOracleAdapterInitialized,
  handlePauseSet,
  handleAdapterAdminSet,
  handleMultiPythOracleAdapterInitialized,
  handleFeedsSet,
  handleFeedMaxAgeSet,
  handleMultiPauseSet,
  handleMultiAdapterAdminSet,
} from "../../src/oracle-adapter";
import {
  PythOracleAdapter,
  MultiPythOracleAdapter,
  FeedConfig,
} from "../../generated/schema";

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

// --- Multi Pyth ---

describe("handleMultiPythOracleAdapterInitialized", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates MultiPythOracleAdapter and FeedConfig entities", () => {
    let priceIds: Bytes[] = [PRICE_ID, PRICE_ID_2];
    let maxAges: BigInt[] = [BigInt.fromI32(300), BigInt.fromI32(600)];

    let event = createMultiPythOracleAdapterInitializedEvent(
      ADAPTER,
      SENDER,
      VAULT,
      priceIds,
      maxAges,
      ADMIN
    );
    handleMultiPythOracleAdapterInitialized(event);

    assert.entityCount("MultiPythOracleAdapter", 1);
    let id = ADAPTER.toHexString();
    assert.fieldEquals(
      "MultiPythOracleAdapter",
      id,
      "vault",
      VAULT.toHexString()
    );
    assert.fieldEquals(
      "MultiPythOracleAdapter",
      id,
      "admin",
      ADMIN.toHexString()
    );
    assert.fieldEquals("MultiPythOracleAdapter", id, "isPaused", "false");
    assert.fieldEquals("MultiPythOracleAdapter", id, "feedCount", "2");

    // Verify feed configs
    assert.entityCount("FeedConfig", 2);

    let feed0Id = ADAPTER.concatI32(0).toHexString();
    assert.fieldEquals("FeedConfig", feed0Id, "index", "0");
    assert.fieldEquals(
      "FeedConfig",
      feed0Id,
      "priceId",
      PRICE_ID.toHexString()
    );
    assert.fieldEquals("FeedConfig", feed0Id, "maxAge", "300");

    let feed1Id = ADAPTER.concatI32(1).toHexString();
    assert.fieldEquals("FeedConfig", feed1Id, "index", "1");
    assert.fieldEquals(
      "FeedConfig",
      feed1Id,
      "priceId",
      PRICE_ID_2.toHexString()
    );
    assert.fieldEquals("FeedConfig", feed1Id, "maxAge", "600");
  });
});

describe("handleFeedsSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("replaces feeds and updates feedCount", () => {
    // Pre-create adapter with 2 feeds
    let adapter = new MultiPythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.admin = ADMIN;
    adapter.isPaused = false;
    adapter.feedCount = BigInt.fromI32(2);
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let feed0 = new FeedConfig(ADAPTER.concatI32(0));
    feed0.adapter = ADAPTER;
    feed0.index = BigInt.fromI32(0);
    feed0.priceId = PRICE_ID;
    feed0.maxAge = BigInt.fromI32(300);
    feed0.save();

    let feed1 = new FeedConfig(ADAPTER.concatI32(1));
    feed1.adapter = ADAPTER;
    feed1.index = BigInt.fromI32(1);
    feed1.priceId = PRICE_ID_2;
    feed1.maxAge = BigInt.fromI32(600);
    feed1.save();

    // Replace with 3 feeds
    let newPriceIds: Bytes[] = [PRICE_ID, PRICE_ID_2, PRICE_ID_3];
    let newMaxAges: BigInt[] = [
      BigInt.fromI32(200),
      BigInt.fromI32(400),
      BigInt.fromI32(800),
    ];

    let event = createFeedsSetEvent(ADAPTER, newPriceIds, newMaxAges);
    handleFeedsSet(event);

    assert.fieldEquals(
      "MultiPythOracleAdapter",
      ADAPTER.toHexString(),
      "feedCount",
      "3"
    );
    assert.entityCount("FeedConfig", 3);

    // First feed updated
    assert.fieldEquals(
      "FeedConfig",
      ADAPTER.concatI32(0).toHexString(),
      "maxAge",
      "200"
    );
    // New third feed
    assert.fieldEquals(
      "FeedConfig",
      ADAPTER.concatI32(2).toHexString(),
      "priceId",
      PRICE_ID_3.toHexString()
    );
  });

  test("removes stale FeedConfig when count shrinks", () => {
    // Pre-create adapter with 3 feeds
    let adapter = new MultiPythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.admin = ADMIN;
    adapter.isPaused = false;
    adapter.feedCount = BigInt.fromI32(3);
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    for (let i = 0; i < 3; i++) {
      let feed = new FeedConfig(ADAPTER.concatI32(i));
      feed.adapter = ADAPTER;
      feed.index = BigInt.fromI32(i);
      feed.priceId = PRICE_ID;
      feed.maxAge = BigInt.fromI32(300);
      feed.save();
    }

    assert.entityCount("FeedConfig", 3);

    // Shrink to 1 feed
    let newPriceIds: Bytes[] = [PRICE_ID_2];
    let newMaxAges: BigInt[] = [BigInt.fromI32(500)];
    let event = createFeedsSetEvent(ADAPTER, newPriceIds, newMaxAges);
    handleFeedsSet(event);

    assert.fieldEquals(
      "MultiPythOracleAdapter",
      ADAPTER.toHexString(),
      "feedCount",
      "1"
    );
    // Only 1 feed config remains
    assert.entityCount("FeedConfig", 1);
    assert.fieldEquals(
      "FeedConfig",
      ADAPTER.concatI32(0).toHexString(),
      "priceId",
      PRICE_ID_2.toHexString()
    );
    assert.fieldEquals(
      "FeedConfig",
      ADAPTER.concatI32(0).toHexString(),
      "maxAge",
      "500"
    );
  });
});

describe("handleFeedMaxAgeSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates maxAge on specific feed", () => {
    let feed = new FeedConfig(ADAPTER.concatI32(1));
    feed.adapter = ADAPTER;
    feed.index = BigInt.fromI32(1);
    feed.priceId = PRICE_ID_2;
    feed.maxAge = BigInt.fromI32(600);
    feed.save();

    let event = createFeedMaxAgeSetEvent(
      ADAPTER,
      BigInt.fromI32(1),
      BigInt.fromI32(900)
    );
    handleFeedMaxAgeSet(event);

    assert.fieldEquals(
      "FeedConfig",
      ADAPTER.concatI32(1).toHexString(),
      "maxAge",
      "900"
    );
    // priceId unchanged
    assert.fieldEquals(
      "FeedConfig",
      ADAPTER.concatI32(1).toHexString(),
      "priceId",
      PRICE_ID_2.toHexString()
    );
  });
});

describe("handleMultiPauseSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("pauses multi adapter and creates PauseEvent", () => {
    let adapter = new MultiPythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.admin = ADMIN;
    adapter.isPaused = false;
    adapter.feedCount = BigInt.fromI32(1);
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createMultiPauseSetEvent(ADAPTER, true);
    handleMultiPauseSet(event);

    assert.fieldEquals(
      "MultiPythOracleAdapter",
      ADAPTER.toHexString(),
      "isPaused",
      "true"
    );
    assert.entityCount("PauseEvent", 1);

    let pauseId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals("PauseEvent", pauseId, "isPaused", "true");
    assert.fieldEquals(
      "PauseEvent",
      pauseId,
      "adapter",
      ADAPTER.toHexString()
    );
  });
});

describe("handleMultiAdapterAdminSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates multi adapter admin and creates change", () => {
    let adapter = new MultiPythOracleAdapter(ADAPTER);
    adapter.vault = VAULT;
    adapter.admin = ADMIN;
    adapter.isPaused = false;
    adapter.feedCount = BigInt.fromI32(1);
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createMultiAdminSetEvent(ADAPTER, ADMIN, NEW_ADMIN);
    handleMultiAdapterAdminSet(event);

    assert.fieldEquals(
      "MultiPythOracleAdapter",
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
