import assert from "node:assert/strict";
import test from "node:test";
import { parseClientEnvelope } from "../src/protocol.js";
import { NodeLocalBounds, parseNodeLocalBounds } from "../src/node-local-bounds.js";
import { AstraSession } from "../src/session.js";
import { ModelEvent, ModelRequest, ModelTransport, formatUserInput } from "../src/astra/client.js";
import { JsonObject } from "../src/json.js";

const document: JsonObject = { nodes: [{ nodeId: "lamp", parentId: null, semantic: { name: "Lamp" } }, { nodeId: "lens", parentId: "lamp", semantic: { name: "Lens" } }] };
const bounds: NodeLocalBounds[] = [{ nodeId: "lens", minimum: [-0.123456789012345, 0, -4.5], maximum: [0.9999999999999, 0, 4.5] }];
const snapshot = { type: "phone.snapshot" as const, sceneId: "scene", revision: 1, intentEpoch: 2, document, nodeLocalBounds: bounds };
const hello = { type: "session.hello" as const, protocolVersion: 1, sessionId: "bounds-test", sceneId: "scene", revision: 1, intentEpoch: 2, sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: ["box.v1", "flow.v1"] };
const explain = JSON.stringify({ mode: "explanation", explanation: "The measured bounds are local to this component.", scopeParentNodeId: null, operations: [] });

test("measured bounds preserve exact coordinates and zero-volume axes without rounding", () => {
  const message = parseClientEnvelope(snapshot);
  assert.equal(message.type, "phone.snapshot");
  if (message.type !== "phone.snapshot") assert.fail();
  assert.deepEqual(message.nodeLocalBounds, bounds);
  assert.notEqual(message.nodeLocalBounds, bounds);
  assert.notEqual(message.nodeLocalBounds![0]!.minimum, bounds[0]!.minimum);
  assert.deepEqual(parseNodeLocalBounds([], document), []);
});

test("bounds are optional for legacy snapshots and reject null rather than treating it as absent", () => {
  const { nodeLocalBounds: _bounds, ...legacy } = snapshot;
  const message = parseClientEnvelope(legacy);
  assert.equal("nodeLocalBounds" in message, false);
  assert.throws(() => parseClientEnvelope({ ...legacy, nodeLocalBounds: null }), /at most 128/);
});

test("bounds bind only unique node identities in the exact accompanying snapshot", () => {
  assert.throws(() => parseClientEnvelope({ ...snapshot, document: { nodes: [{ nodeId: "other" }] } }), /same snapshot/);
  assert.throws(() => parseClientEnvelope({ ...snapshot, nodeLocalBounds: [bounds[0], bounds[0]] }), /unique nodes/);
  assert.throws(() => parseClientEnvelope({ ...snapshot, nodeLocalBounds: [{ ...bounds[0], nodeId: "absent" }] }), /same snapshot/);
  assert.throws(() => parseClientEnvelope({ ...snapshot, nodeLocalBounds: [{ ...bounds[0], extra: "invented measurement" }] }), /unknown property/);
});

test("measured bounds have a strict 128-record budget", () => {
  const nodes = Array.from({ length: 129 }, (_, index) => ({ nodeId: `part-${index}` }));
  const records = nodes.map(node => ({ nodeId: node.nodeId, minimum: [0, 0, 0], maximum: [1, 1, 1] }));
  assert.equal(parseNodeLocalBounds(records.slice(0, 128), { nodes }).length, 128);
  assert.throws(() => parseNodeLocalBounds(records, { nodes }), /at most 128/);
});

test("bounds reject malformed, nonfinite, reversed, and unknown fields", () => {
  for (const vector of [null, [], [1, 2], [1, 2, 3, 4], [NaN, 0, 0], [Infinity, 0, 0], [-Infinity, 0, 0], ["0", 0, 0]]) {
    assert.throws(() => parseNodeLocalBounds([{ ...bounds[0], minimum: vector }], document));
    assert.throws(() => parseNodeLocalBounds([{ ...bounds[0], maximum: vector }], document));
  }
  for (const axis of [0, 1, 2]) {
    const minimum = [0, 0, 0]; const maximum = [1, 1, 1]; minimum[axis] = 2;
    assert.throws(() => parseNodeLocalBounds([{ nodeId: "lens", minimum, maximum }], document), /minimum must not exceed/);
  }
  assert.throws(() => parseNodeLocalBounds([{ ...bounds[0], source: "provider" }], document), /unknown property/);
});

test("flow model receives a private copy of exact bounds admitted with its scene", async () => {
  const requests: ModelRequest[] = [];
  const model: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> { requests.push(request); yield { type: "function_call", name: "propose_scene", arguments: explain }; yield { type: "done" }; } };
  const session = new AstraSession(model, { send() {} });
  try {
    session.acceptHello(hello); session.updateSnapshot(snapshot);
    await session.request({ type: "user.request", requestId: "first", text: "Explain the selected component" });
    assert.equal(requests[0]!.flowEnabled, true);
    assert.deepEqual(requests[0]!.nodeLocalBounds, bounds);
    assert.deepEqual(JSON.parse(formatUserInput(requests[0]!)).nodeLocalBounds, bounds);
    requests[0]!.nodeLocalBounds![0]!.minimum[0] = -999;
    await session.request({ type: "user.request", requestId: "second", text: "Use the original measured bounds" });
    assert.deepEqual(requests[1]!.nodeLocalBounds, bounds);
    assert.deepEqual(bounds[0]!.minimum, [-0.123456789012345, 0, -4.5]);
  } finally { session.dispose(); }
});

test("legacy capabilities do not expose flow tools or measured flow context", async () => {
  let request: ModelRequest | undefined;
  const model: ModelTransport = { async *stream(value): AsyncIterable<ModelEvent> { request = value; yield { type: "function_call", name: "propose_scene", arguments: explain }; yield { type: "done" }; } };
  const session = new AstraSession(model, { send() {} });
  try {
    session.acceptHello({ ...hello, capabilities: ["box.v1"] }); session.updateSnapshot(snapshot);
    await session.request({ type: "user.request", requestId: "legacy", text: "Explain the scene" });
    assert.equal(request!.flowEnabled, false); assert.equal(request!.nodeLocalBounds, undefined);
    assert.equal("nodeLocalBounds" in JSON.parse(formatUserInput(request!)), false);
  } finally { session.dispose(); }
});

test("a replacement snapshot cannot change bounds already admitted to a suspended model", async () => {
  let captured: ModelRequest | undefined; let resume: (() => void) | undefined;
  const sent: JsonObject[] = [];
  const model: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> {
    captured = request; await new Promise<void>(resolve => { resume = resolve; });
    yield { type: "function_call", name: "propose_scene", arguments: explain }; yield { type: "done" };
  } };
  const session = new AstraSession(model, { send: message => sent.push(message) });
  try {
    session.acceptHello(hello); session.updateSnapshot(snapshot);
    const pending = session.request({ type: "user.request", requestId: "suspended", text: "Explain" });
    await new Promise(resolve => setImmediate(resolve));
    session.updateSnapshot({ ...snapshot, revision: 2, nodeLocalBounds: [{ ...bounds[0]!, minimum: [-9, -9, -9] }] });
    assert.deepEqual(captured!.nodeLocalBounds, bounds);
    resume!(); await pending;
    assert.ok(sent.some(message => message.code === "stale_model_result"));
    assert.equal(sent.some(message => message.type === "session.explanation"), false);
  } finally { session.dispose(); }
});

test("direct session admission also validates bounds before replacing the accepted mirror", () => {
  const session = new AstraSession({ async *stream() {} }, { send() {} });
  try {
    session.acceptHello(hello); session.updateSnapshot(snapshot);
    assert.throws(() => session.updateSnapshot({ ...snapshot, nodeLocalBounds: [{ ...bounds[0]!, nodeId: "not-in-document" }] }), /same snapshot/);
  } finally { session.dispose(); }
});
