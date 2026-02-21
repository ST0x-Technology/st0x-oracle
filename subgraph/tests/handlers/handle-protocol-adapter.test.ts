import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address, Bytes, BigInt } from "@graphprotocol/graph-ts";
import {
  createMorphoInitializedEvent,
  createMorphoAdminSetEvent,
  createMorphoRegistrySetEvent,
  createPassthroughInitializedEvent,
  createPassthroughAdminSetEvent,
  createPassthroughRegistrySetEvent,
} from "../event-mocks.test";
import {
  handleMorphoInitialized,
  handleMorphoAdminSet,
  handleMorphoRegistrySet,
  handlePassthroughInitialized,
  handlePassthroughAdminSet,
  handlePassthroughRegistrySet,
} from "../../src/protocol-adapter";
import {
  MorphoProtocolAdapter,
  PassthroughProtocolAdapter,
} from "../../generated/schema";

let MORPHO_ADDR = Address.fromString(
  "0x9e775f2ab11e49e18924379a31502a8b593bbec7"
);
let PASSTHROUGH_ADDR = Address.fromString(
  "0x2f179ee0f7ec2767c48e6c43fb6f0c7c715b5880"
);
let SENDER = Address.fromString(
  "0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b"
);
let REGISTRY = Address.fromString(
  "0x36a14d00a8597731fb6dB1e0e7EeA0BB81ffD156"
);
let NEW_REGISTRY = Address.fromString(
  "0x2222222222222222222222222222222222222222"
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

// --- Morpho ---

describe("handleMorphoInitialized", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates MorphoProtocolAdapter with all fields", () => {
    let event = createMorphoInitializedEvent(
      MORPHO_ADDR,
      SENDER,
      REGISTRY,
      VAULT,
      ADMIN
    );
    handleMorphoInitialized(event);

    assert.entityCount("MorphoProtocolAdapter", 1);
    let id = MORPHO_ADDR.toHexString();
    assert.fieldEquals(
      "MorphoProtocolAdapter",
      id,
      "vault",
      VAULT.toHexString()
    );
    assert.fieldEquals(
      "MorphoProtocolAdapter",
      id,
      "registry",
      REGISTRY.toHexString()
    );
    assert.fieldEquals(
      "MorphoProtocolAdapter",
      id,
      "admin",
      ADMIN.toHexString()
    );
    assert.entityCount("Transaction", 1);
  });
});

describe("handleMorphoAdminSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates admin and creates AdapterAdminChange", () => {
    // Pre-create adapter
    let adapter = new MorphoProtocolAdapter(MORPHO_ADDR);
    adapter.vault = VAULT;
    adapter.registry = REGISTRY;
    adapter.admin = ADMIN;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createMorphoAdminSetEvent(MORPHO_ADDR, ADMIN, NEW_ADMIN);
    handleMorphoAdminSet(event);

    assert.fieldEquals(
      "MorphoProtocolAdapter",
      MORPHO_ADDR.toHexString(),
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
      MORPHO_ADDR.toHexString()
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

  test("creates change even without pre-existing adapter", () => {
    let event = createMorphoAdminSetEvent(MORPHO_ADDR, ADMIN, NEW_ADMIN);
    handleMorphoAdminSet(event);

    assert.entityCount("AdapterAdminChange", 1);
    assert.entityCount("MorphoProtocolAdapter", 0);
  });
});

describe("handleMorphoRegistrySet", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates registry and creates RegistryChange", () => {
    let adapter = new MorphoProtocolAdapter(MORPHO_ADDR);
    adapter.vault = VAULT;
    adapter.registry = REGISTRY;
    adapter.admin = ADMIN;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createMorphoRegistrySetEvent(
      MORPHO_ADDR,
      REGISTRY,
      NEW_REGISTRY
    );
    handleMorphoRegistrySet(event);

    assert.fieldEquals(
      "MorphoProtocolAdapter",
      MORPHO_ADDR.toHexString(),
      "registry",
      NEW_REGISTRY.toHexString()
    );
    assert.entityCount("RegistryChange", 1);

    let changeId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "RegistryChange",
      changeId,
      "adapter",
      MORPHO_ADDR.toHexString()
    );
    assert.fieldEquals(
      "RegistryChange",
      changeId,
      "oldRegistry",
      REGISTRY.toHexString()
    );
    assert.fieldEquals(
      "RegistryChange",
      changeId,
      "newRegistry",
      NEW_REGISTRY.toHexString()
    );
  });
});

// --- Passthrough ---

describe("handlePassthroughInitialized", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates PassthroughProtocolAdapter with all fields", () => {
    let event = createPassthroughInitializedEvent(
      PASSTHROUGH_ADDR,
      SENDER,
      REGISTRY,
      VAULT,
      ADMIN
    );
    handlePassthroughInitialized(event);

    assert.entityCount("PassthroughProtocolAdapter", 1);
    let id = PASSTHROUGH_ADDR.toHexString();
    assert.fieldEquals(
      "PassthroughProtocolAdapter",
      id,
      "vault",
      VAULT.toHexString()
    );
    assert.fieldEquals(
      "PassthroughProtocolAdapter",
      id,
      "registry",
      REGISTRY.toHexString()
    );
    assert.fieldEquals(
      "PassthroughProtocolAdapter",
      id,
      "admin",
      ADMIN.toHexString()
    );
    assert.entityCount("Transaction", 1);
  });
});

describe("handlePassthroughAdminSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates admin and creates AdapterAdminChange", () => {
    let adapter = new PassthroughProtocolAdapter(PASSTHROUGH_ADDR);
    adapter.vault = VAULT;
    adapter.registry = REGISTRY;
    adapter.admin = ADMIN;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createPassthroughAdminSetEvent(
      PASSTHROUGH_ADDR,
      ADMIN,
      NEW_ADMIN
    );
    handlePassthroughAdminSet(event);

    assert.fieldEquals(
      "PassthroughProtocolAdapter",
      PASSTHROUGH_ADDR.toHexString(),
      "admin",
      NEW_ADMIN.toHexString()
    );
    assert.entityCount("AdapterAdminChange", 1);
  });
});

describe("handlePassthroughRegistrySet", () => {
  afterEach(() => {
    clearStore();
  });

  test("updates registry and creates RegistryChange", () => {
    let adapter = new PassthroughProtocolAdapter(PASSTHROUGH_ADDR);
    adapter.vault = VAULT;
    adapter.registry = REGISTRY;
    adapter.admin = ADMIN;
    adapter.createdAt = BigInt.fromI32(1000);
    adapter.createdTransaction = Bytes.fromHexString("0xaa");
    adapter.save();

    let event = createPassthroughRegistrySetEvent(
      PASSTHROUGH_ADDR,
      REGISTRY,
      NEW_REGISTRY
    );
    handlePassthroughRegistrySet(event);

    assert.fieldEquals(
      "PassthroughProtocolAdapter",
      PASSTHROUGH_ADDR.toHexString(),
      "registry",
      NEW_REGISTRY.toHexString()
    );
    assert.entityCount("RegistryChange", 1);

    let changeId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "RegistryChange",
      changeId,
      "oldRegistry",
      REGISTRY.toHexString()
    );
    assert.fieldEquals(
      "RegistryChange",
      changeId,
      "newRegistry",
      NEW_REGISTRY.toHexString()
    );
  });
});
