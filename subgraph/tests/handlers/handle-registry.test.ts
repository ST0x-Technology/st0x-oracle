import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address, Bytes } from "@graphprotocol/graph-ts";
import {
  createOracleRegistryInitializedEvent,
  createOracleSetEvent,
  createAdminSetEvent,
} from "../event-mocks.test";
import {
  handleOracleRegistryInitialized,
  handleOracleSet,
  handleRegistryAdminSet,
} from "../../src/registry";
import { OracleRegistry } from "../../generated/schema";

let ADMIN = Address.fromString(
  "0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b"
);
let NEW_ADMIN = Address.fromString(
  "0x1111111111111111111111111111111111111111"
);
let VAULT = Address.fromString(
  "0x5cDa0E1CA4ce2af96315f7F8963C85399c172204"
);
let ZERO = Address.fromString(
  "0x0000000000000000000000000000000000000000"
);
let ORACLE_A = Address.fromString(
  "0x1C63889a9FAd36C6a4422B3dAFCD57b11deC73d8"
);
let ORACLE_B = Address.fromString(
  "0x9e775f2ab11e49e18924379a31502a8b593bbec7"
);

describe("handleOracleRegistryInitialized", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates OracleRegistry with correct admin", () => {
    let event = createOracleRegistryInitializedEvent(ADMIN, ADMIN);
    handleOracleRegistryInitialized(event);

    assert.entityCount("OracleRegistry", 1);
    assert.fieldEquals(
      "OracleRegistry",
      event.address.toHexString(),
      "admin",
      ADMIN.toHexString()
    );
    assert.entityCount("Transaction", 1);
  });
});

describe("handleOracleSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates OracleMapping and OracleChange with correct fields", () => {
    let event = createOracleSetEvent(VAULT, ZERO, ORACLE_A);
    handleOracleSet(event);

    assert.entityCount("OracleMapping", 1);
    assert.entityCount("OracleChange", 1);
    assert.entityCount("Transaction", 1);

    // Verify mapping fields
    let mappingId = event.address.concat(VAULT).toHexString();
    assert.fieldEquals("OracleMapping", mappingId, "vault", VAULT.toHexString());
    assert.fieldEquals(
      "OracleMapping",
      mappingId,
      "oracle",
      ORACLE_A.toHexString()
    );
    assert.fieldEquals(
      "OracleMapping",
      mappingId,
      "registry",
      event.address.toHexString()
    );

    // Verify change fields
    let changeId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "OracleChange",
      changeId,
      "vault",
      VAULT.toHexString()
    );
    assert.fieldEquals(
      "OracleChange",
      changeId,
      "oldOracle",
      ZERO.toHexString()
    );
    assert.fieldEquals(
      "OracleChange",
      changeId,
      "newOracle",
      ORACLE_A.toHexString()
    );
  });

  test("updates existing mapping oracle on second call", () => {
    let event1 = createOracleSetEvent(VAULT, ZERO, ORACLE_A);
    handleOracleSet(event1);

    let event2 = createOracleSetEvent(VAULT, ORACLE_A, ORACLE_B);
    handleOracleSet(event2);

    // Still one mapping
    assert.entityCount("OracleMapping", 1);
    // But two changes
    assert.entityCount("OracleChange", 2);

    // Mapping now points to ORACLE_B
    let mappingId = event1.address.concat(VAULT).toHexString();
    assert.fieldEquals(
      "OracleMapping",
      mappingId,
      "oracle",
      ORACLE_B.toHexString()
    );
  });

  test("creates separate mappings for different vaults", () => {
    let vault2 = Address.fromString(
      "0x2222222222222222222222222222222222222222"
    );
    let event1 = createOracleSetEvent(VAULT, ZERO, ORACLE_A);
    handleOracleSet(event1);

    let event2 = createOracleSetEvent(vault2, ZERO, ORACLE_B);
    handleOracleSet(event2);

    assert.entityCount("OracleMapping", 2);
    assert.entityCount("OracleChange", 2);
  });
});

describe("handleRegistryAdminSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("creates RegistryAdminChange and updates registry admin", () => {
    let event = createAdminSetEvent(ADMIN, NEW_ADMIN);

    // Pre-create registry
    let registry = new OracleRegistry(event.address);
    registry.admin = ADMIN;
    registry.save();

    handleRegistryAdminSet(event);

    assert.entityCount("RegistryAdminChange", 1);

    let changeId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "RegistryAdminChange",
      changeId,
      "oldAdmin",
      ADMIN.toHexString()
    );
    assert.fieldEquals(
      "RegistryAdminChange",
      changeId,
      "newAdmin",
      NEW_ADMIN.toHexString()
    );
    assert.fieldEquals(
      "RegistryAdminChange",
      changeId,
      "registry",
      event.address.toHexString()
    );

    // Registry admin updated
    assert.fieldEquals(
      "OracleRegistry",
      event.address.toHexString(),
      "admin",
      NEW_ADMIN.toHexString()
    );
  });

  test("creates change even without pre-existing registry", () => {
    let event = createAdminSetEvent(ADMIN, NEW_ADMIN);
    handleRegistryAdminSet(event);

    assert.entityCount("RegistryAdminChange", 1);
    // No registry entity should exist (wasn't pre-created)
    assert.entityCount("OracleRegistry", 0);
  });
});
