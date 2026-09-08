import assert from "node:assert/strict";
import test from "node:test";
import { AstraSession } from "../src/session.js";
import { ModelEvent, ModelRequest, ModelTransport } from "../src/astra/client.js";
import { JsonObject } from "../src/json.js";
import { geometryContentHash, payloadHash } from "../src/normalizer.js";

class ScriptedModel implements ModelTransport {
  constructor(private readonly events: ModelEvent[]) {}
  async *stream(_request: ModelRequest): AsyncIterable<ModelEvent> { yield* this.events; }
}

const hello = { type: "session.hello" as const, protocolVersion: 1, sessionId: "test", sceneId: "scene_test", revision: 0, intentEpoch: 1, sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: ["box.v1"] };
const snapshot = { type: "phone.snapshot" as const, sceneId: "scene_test", revision: 0, intentEpoch: 1, document: { nodes: [] } };
const proposal = JSON.stringify({
  mode: "generation", explanation: "This box gives the user a simple tangible starting point.", scopeParentNodeId: null,
  operations: [
    { kind: "geometry", alias: "fan-body", recipe: { kind: "box", size: [0.2, 0.1, 0.3] } },
    { kind: "material", alias: "steel", material: { kind: "pbr", baseColorLinear: [0.2, 0.2, 0.2, 1], metallic: 0.7, roughness: 0.4 } },
    { kind: "node", alias: "server", node: { geometryAlias: "fan-body", materialAlias: "steel", transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }, semantic: { name: "Server", role: "example", description: "Illustrative server" }, provenance: { origin: "generated", factualSupport: "illustrative", sourceRefs: [] } } }
  ]
});

test("streams a complete function call into exact scene envelopes and waits for receipt before explanation", async () => {
  const sent: JsonObject[] = [];
  const session = new AstraSession(new ScriptedModel([{ type: "function_call", name: "propose_scene", arguments: proposal }, { type: "done" }]), { send: (message) => sent.push(message) });
  session.acceptHello(hello);
  session.updateSnapshot(snapshot);
  await session.request({ type: "user.request", requestId: "request_1", text: "show me a server" });

  const batch = sent.find((message) => message.type === "generation.batch");
  assert.ok(batch);
  assert.equal(typeof batch.payloadHash, "string");
  assert.equal(sent.some((message) => message.type === "session.explanation"), false);
  session.receiveReceipt({ type: "scene.receipt", protocolVersion: 1, sceneId: "scene_test", requestId: batch.requestId as string, generationId: batch.generationId as string, sequence: 1, status: "installed", revision: 1, affectedNodeIds: [] });
  assert.equal(sent.filter((message) => message.type === "session.explanation").length, 1);
});

test("never retags a model result after the device advances revision", async () => {
  let release: (() => void) | undefined;
  const model: ModelTransport = { async *stream(): AsyncIterable<ModelEvent> {
    await new Promise<void>((resolve) => { release = resolve; });
    yield { type: "function_call", name: "propose_scene", arguments: proposal };
  }};
  const sent: JsonObject[] = [];
  const session = new AstraSession(model, { send: (message) => sent.push(message) });
  session.acceptHello(hello);
  session.updateSnapshot(snapshot);
  const request = session.request({ type: "user.request", requestId: "request_stale", text: "show me a server" });
  await new Promise<void>((resolve) => setImmediate(resolve));
  session.updateSnapshot({ ...snapshot, revision: 1 });
  release?.();
  await request;
  assert.equal(sent.some((message) => message.type === "generation.batch" || message.type === "scene.patch"), false);
  assert.equal(sent.some((message) => message.type === "session.error" && message.code === "stale_model_result"), true);
});

test("repairs one semantic proposal rejection before any device mutation", async () => {
  let calls = 0;
  const model: ModelTransport = { async *stream(): AsyncIterable<ModelEvent> {
    calls += 1;
    yield { type: "function_call", name: "propose_scene", arguments: calls === 1
      ? JSON.stringify({ mode: "generation", explanation: "Bad proposal", scopeParentNodeId: null, operations: [{ kind: "geometry", alias: "bad", recipe: { kind: "box", size: [1, 2] } }] })
      : proposal };
  }};
  const sent: JsonObject[] = [];
  const session = new AstraSession(model, { send: (message) => sent.push(message) });
  session.acceptHello(hello); session.updateSnapshot(snapshot);
  await session.request({ type: "user.request", requestId: "request_repair", text: "show a server" });
  assert.equal(calls, 2);
  assert.equal(sent.some((message) => message.type === "session.progress" && message.status === "repairing_proposal"), true);
  assert.equal(sent.some((message) => message.type === "generation.batch"), true);
});

test("delivers a read-only explanation without creating a scene mutation", async () => {
  const sent: JsonObject[] = [];
  const model = new ScriptedModel([{ type: "function_call", name: "propose_scene", arguments: JSON.stringify({ mode: "explanation", explanation: "I need to know which fan you mean.", scopeParentNodeId: null, operations: [] }) }]);
  const session = new AstraSession(model, { send: (message) => sent.push(message) });
  session.acceptHello(hello); session.updateSnapshot(snapshot);
  await session.request({ type: "user.request", requestId: "request_explain", text: "Explain this" });
  assert.equal(sent.filter((message) => message.type === "session.explanation").length, 1);
  assert.equal(sent.some((message) => ["generation.begin", "generation.batch", "generation.finish", "scene.patch"].includes(message.type as string)), false);
});

test("matches the shared Astra Canonical Request v1 hash vectors", () => {
  const batch = {
    type: "generation.batch", protocolVersion: 1, requestId: "request_batch_1", sceneId: "scene_fixture", generationId: "generation_1", intentEpoch: 3, sequence: 1,
    operations: [
      { op: "put.geometry", geometry: { geometryId: "geometry_box", contentHash: "10a4501e9bb51222f3d933d4e2b441b2bfa333c67a6d9784af35571168f72fdb", recipe: { kind: "box", size: [0.4, 0.2, 0.6] } } },
      { op: "create.node", node: { nodeId: "node_box", parentId: "node_group", geometryId: "geometry_box", materialId: "material_blue", transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }, isVisible: true, semantic: { name: "Box" }, provenance: { origin: "generated", factualSupport: "illustrative", sourceRefs: [] } } }
    ]
  } as unknown as JsonObject;
  const patch = {
    type: "scene.patch", protocolVersion: 1, requestId: "request_patch_1", sceneId: "scene_fixture", intentEpoch: 3, baseRevision: 7,
    operations: [
      { op: "put.material", material: { materialId: "material_blue", baseColorLinear: [0.05, 0.2, 0.8, 1], metallic: 0.2, roughness: 0.6 } },
      { op: "set.material", nodeId: "node_group", materialId: "material_blue" }
    ]
  } as unknown as JsonObject;
  assert.equal(payloadHash(batch), "747815843c7f19dfe783690a2220d8b6d6fe9b37449b1250e6ece98d16a1f678");
  assert.equal(payloadHash(patch), "be713f08cdf4a851b1cbde720df96af7d697701eaab9561f60699e2fc7a1f1e6");
  assert.equal(geometryContentHash({ kind: "box", size: [0.4, 0.2, 0.6] }), "10a4501e9bb51222f3d933d4e2b441b2bfa333c67a6d9784af35571168f72fdb");
});
