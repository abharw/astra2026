import assert from "node:assert/strict";
import test from "node:test";
import { AstraSession } from "../src/session.js";
import { ModelEvent, ModelRequest, ModelTransport } from "../src/astra/client.js";
import { JsonObject } from "../src/json.js";

const hello = { type: "session.hello" as const, protocolVersion: 1, sessionId: "flow-test", sceneId: "scene", revision: 0, intentEpoch: 1, sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: ["box.v1", "flow.v1"] };
const transform = { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] };
const snapshot = { type: "phone.snapshot" as const, sceneId: "scene", revision: 0, intentEpoch: 1, document: { nodes: [
  { nodeId: "lamp", parentId: null, transform, semantic: { name: "Lamp" } },
  { nodeId: "lens", parentId: "lamp", transform, semantic: { name: "Lens" } }
] }, nodeLocalBounds: [{ nodeId: "lens", minimum: [-1, -1, -1], maximum: [1, 1, 1] }] };
const flow = { kind: "flow", alias: "light-path", parentNodeRef: null,
  source: { nodeId: "lamp", localPoint: [0, 0, 0] }, target: { nodeId: "lens", localPoint: [0, 0, 0] },
  routePoints: [], direction: "forward", width: 0.01, label: "Light path", animated: true, color: [1, 0.8, 0.2, 1] };
const proposal = JSON.stringify({ mode: "patch", explanation: "The editable path follows the selected lamp and lens.", scopeParentNodeId: null, operations: [flow] });

test("flow capability admits a normal scene patch and keeps explanation receipt-gated", async () => {
  const requests: ModelRequest[] = []; const sent: JsonObject[] = [];
  const model: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> { requests.push(request); yield { type: "function_call", name: "propose_scene", arguments: proposal }; yield { type: "done" }; } };
  const session = new AstraSession(model, { send: message => sent.push(message) });
  try {
    session.acceptHello(hello); session.updateSnapshot(snapshot);
    await session.request({ type: "user.request", requestId: "make-flow", text: "Show light moving through the lens" });
    assert.equal(requests[0]!.flowEnabled, true); assert.deepEqual(requests[0]!.nodeLocalBounds, snapshot.nodeLocalBounds);
    const patch = sent.find(message => message.type === "scene.patch")!;
    assert.ok(patch); assert.equal(typeof patch.payloadHash, "string");
    assert.deepEqual((patch.operations as JsonObject[]).map(operation => operation.op), ["put.geometry", "put.material", "create.node"]);
    assert.equal(((patch.operations as JsonObject[])[0]!.geometry as JsonObject).recipe && ((((patch.operations as JsonObject[])[0]!.geometry as JsonObject).recipe as JsonObject).kind), "flow");
    assert.equal(sent.some(message => message.type === "session.explanation"), false);
    session.receiveReceipt({ type: "scene.receipt", protocolVersion: 1, sceneId: "scene", requestId: String(patch.requestId), status: "installed", revision: 1, affectedNodeIds: ["new-flow"] });
    assert.equal(sent.filter(message => message.type === "session.explanation").length, 1);
    assert.equal(sent.some(message => message.type === "illustration.state"), false);
  } finally { session.dispose(); }
});

test("provider-injected flow never reaches a client without flow.v1, including the repair attempt", async () => {
  let calls = 0; const sent: JsonObject[] = [];
  const model: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> { calls += 1; assert.equal(request.flowEnabled, false); yield { type: "function_call", name: "propose_scene", arguments: proposal }; yield { type: "done" }; } };
  const session = new AstraSession(model, { send: message => sent.push(message) });
  try {
    session.acceptHello({ ...hello, capabilities: ["box.v1"] }); session.updateSnapshot(snapshot);
    await session.request({ type: "user.request", requestId: "unsupported-flow", text: "Show the path" });
    assert.equal(calls, 2);
    assert.equal(sent.some(message => ["scene.patch", "generation.begin", "generation.batch", "generation.finish"].includes(String(message.type))), false);
    assert.ok(sent.some(message => message.type === "session.error" && message.code === "proposal_rejected"));
  } finally { session.dispose(); }
});

test("injected generic flow geometry is subject to the same negotiated capability gate", async () => {
  const { alias: _alias, parentNodeRef: _parent, color: _color, ...recipe } = flow;
  const generic = JSON.stringify({ mode: "patch", explanation: "Prepare geometry", scopeParentNodeId: null, operations: [{ kind: "geometry", alias: "path-geometry", recipe }] });
  const sent: JsonObject[] = [];
  const session = new AstraSession({ async *stream(): AsyncIterable<ModelEvent> { yield { type: "function_call", name: "propose_scene", arguments: generic }; yield { type: "done" }; } }, { send: message => sent.push(message) });
  try {
    session.acceptHello({ ...hello, capabilities: ["box.v1"] }); session.updateSnapshot(snapshot);
    await session.request({ type: "user.request", requestId: "generic-flow", text: "Create geometry" });
    assert.equal(sent.some(message => message.type === "scene.patch"), false);
    assert.ok(sent.some(message => message.code === "proposal_rejected"));
  } finally { session.dispose(); }
});
