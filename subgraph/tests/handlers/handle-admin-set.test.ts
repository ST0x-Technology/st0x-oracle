import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address } from "@graphprotocol/graph-ts";
import { createAdminSetEvent } from "../event-mocks.test";
import { handleRegistryAdminSet } from "../../src/registry";

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

  test("handleRegistryAdminSet() creates RegistryAdminChange", () => {
    let event = createAdminSetEvent(OLD_ADMIN, NEW_ADMIN);
    handleRegistryAdminSet(event);

    assert.entityCount("RegistryAdminChange", 1);
    assert.entityCount("Transaction", 1);
  });
});
