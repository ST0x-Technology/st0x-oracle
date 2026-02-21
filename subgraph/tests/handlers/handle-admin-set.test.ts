import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address, Bytes } from "@graphprotocol/graph-ts";
import { createAdminSetEvent } from "../event-mocks.test";
import { handleRegistryAdminSet } from "../../src/registry";
import { OracleRegistry } from "../../generated/schema";

let OLD_ADMIN = Address.fromString(
  "0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b"
);
let NEW_ADMIN = Address.fromString(
  "0x1111111111111111111111111111111111111111"
);

describe("Handle AdminSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("handleRegistryAdminSet() creates RegistryAdminChange with correct fields", () => {
    let event = createAdminSetEvent(OLD_ADMIN, NEW_ADMIN);

    // Pre-create the registry so the handler's if (registry != null) branch runs
    let registry = new OracleRegistry(event.address);
    registry.admin = OLD_ADMIN;
    registry.save();

    handleRegistryAdminSet(event);

    // Should create a RegistryAdminChange
    assert.entityCount("RegistryAdminChange", 1);

    // Verify the change entity fields
    let changeId = event.transaction.hash
      .concatI32(event.logIndex.toI32())
      .toHexString();
    assert.fieldEquals(
      "RegistryAdminChange",
      changeId,
      "oldAdmin",
      OLD_ADMIN.toHexString()
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

    // Verify registry admin was updated
    assert.fieldEquals(
      "OracleRegistry",
      event.address.toHexString(),
      "admin",
      NEW_ADMIN.toHexString()
    );

    // Transaction created by the handler (not the mock)
    assert.entityCount("Transaction", 1);
  });
});
