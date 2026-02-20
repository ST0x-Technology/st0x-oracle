import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address } from "@graphprotocol/graph-ts";
import { createOracleSetEvent } from "../event-mocks.test";
import { handleOracleSet } from "../../src/registry";

let VAULT = Address.fromString(
  "0x5cDa0E1CA4ce2af96315f7F8963C85399c172204"
);
let OLD_ORACLE = Address.fromString(
  "0x0000000000000000000000000000000000000000"
);
let NEW_ORACLE = Address.fromString(
  "0x1C63889a9FAd36C6a4422B3dAFCD57b11deC73d8"
);

describe("Handle OracleSet", () => {
  afterEach(() => {
    clearStore();
  });

  test("handleOracleSet() creates mapping and change", () => {
    let event = createOracleSetEvent(VAULT, OLD_ORACLE, NEW_ORACLE);
    handleOracleSet(event);

    assert.entityCount("OracleMapping", 1);
    assert.entityCount("OracleChange", 1);
    assert.entityCount("Transaction", 1);
  });

  test("handleOracleSet() updates existing mapping", () => {
    let event1 = createOracleSetEvent(VAULT, OLD_ORACLE, NEW_ORACLE);
    handleOracleSet(event1);

    let NEWER_ORACLE = Address.fromString(
      "0x9e775f2ab11e49e18924379a31502a8b593bbec7"
    );
    let event2 = createOracleSetEvent(VAULT, NEW_ORACLE, NEWER_ORACLE);
    handleOracleSet(event2);

    assert.entityCount("OracleMapping", 1);
    assert.entityCount("OracleChange", 2);
  });
});
