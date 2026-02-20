import {
  test,
  assert,
  clearStore,
  describe,
  afterEach,
} from "matchstick-as";
import { Address } from "@graphprotocol/graph-ts";
import {
  createSingleDeploymentEvent,
  createMultiDeploymentEvent,
} from "../event-mocks.test";
import {
  handleSingleDeployment,
  handleMultiDeployment,
} from "../../src/deployer";

let SENDER = Address.fromString(
  "0x8E4bdeec7CEB9570D440676345dA1dCe10329f5b"
);
let ORACLE = Address.fromString(
  "0x1C63889a9FAd36C6a4422B3dAFCD57b11deC73d8"
);
let MORPHO = Address.fromString(
  "0x9e775f2ab11e49e18924379a31502a8b593bbec7"
);
let PASSTHROUGH = Address.fromString(
  "0x2f179ee0f7ec2767c48e6c43fb6f0c7c715b5880"
);

describe("Handle Deployment", () => {
  afterEach(() => {
    clearStore();
  });

  test("handleSingleDeployment() creates UnifiedDeployment", () => {
    let event = createSingleDeploymentEvent(
      SENDER,
      ORACLE,
      MORPHO,
      PASSTHROUGH
    );
    handleSingleDeployment(event);

    assert.entityCount("UnifiedDeployment", 1);
    assert.entityCount("Transaction", 1);
  });

  test("handleMultiDeployment() creates UnifiedDeployment with kind=multi", () => {
    let event = createMultiDeploymentEvent(
      SENDER,
      ORACLE,
      MORPHO,
      PASSTHROUGH
    );
    handleMultiDeployment(event);

    assert.entityCount("UnifiedDeployment", 1);
    assert.entityCount("Transaction", 1);
  });
});
