import assert from "node:assert/strict";
import test from "node:test";
import { AstraSession } from "../src/session.js";
import { ModelEvent, ModelRequest, ModelTransport, OpenAIResponsesTransport, formatUserInput } from "../src/astra/client.js";
import { JsonObject } from "../src/json.js";
import { geometryContentHash, payloadHash } from "../src/normalizer.js";
import { JsonlLogger } from "../src/diagnostics.js";

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
    yield { type: "done" };
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
    yield { type: "done" };
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
  const model = new ScriptedModel([{ type: "function_call", name: "propose_scene", arguments: JSON.stringify({ mode: "explanation", explanation: "I need to know which fan you mean.", scopeParentNodeId: null, operations: [] }) }, { type: "done" }]);
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

test("diagnostics redact content-bearing fields while preserving correlation fields", () => {
  const lines: string[] = [];
  const logger = new JsonlLogger(undefined, { log: (line: string) => lines.push(line) });
  logger.log("session", "request_error", { sessionId: "session_1", requestId: "request_1", prompt: "private", authToken: "secret", clientSecret: "secret", password: "secret", body: "private", payload: "private", safeError: "Bearer sk_private" }, "warn");
  assert.equal(lines.length, 1);
  const event = JSON.parse(lines[0]!) as Record<string, unknown>;
  assert.equal(event.sessionId, "session_1");
  assert.equal(event.requestId, "request_1");
  assert.equal(event.safeError, "Bearer [redacted]");
  assert.equal("prompt" in event, false);
  assert.equal("authToken" in event, false);
  assert.equal("clientSecret" in event, false);
  assert.equal("password" in event, false);
  assert.equal("body" in event, false);
  assert.equal("payload" in event, false);
});

test("model and receipt deadlines emit bounded errors for only the admitted request", async () => {
  const sent: JsonObject[] = [];
  let timedOutSignal: AbortSignal | undefined;
  const never: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> { timedOutSignal = request.signal; await new Promise((resolve) => request.signal.addEventListener("abort", resolve, { once: true })); } };
  const session = new AstraSession(never, { send: (message) => sent.push(message) }, { modelTimeoutMs: 10, receiptTimeoutMs: 10 });
  session.acceptHello(hello); session.updateSnapshot(snapshot);
  await session.request({ type: "user.request", requestId: "request_timeout", text: "show a server" });
  assert.equal(timedOutSignal?.aborted, true);
  assert.equal(sent.some((message) => message.type === "session.error" && message.requestId === "request_timeout" && message.code === "model_timeout"), true);

  const receiptSent: JsonObject[] = [];
  const fast = new AstraSession(new ScriptedModel([{ type: "function_call", name: "propose_scene", arguments: proposal }, { type: "done" }]), { send: (message) => receiptSent.push(message) }, { receiptTimeoutMs: 10 });
  fast.acceptHello(hello); fast.updateSnapshot(snapshot);
  await fast.request({ type: "user.request", requestId: "request_receipt", text: "show a server" });
  await new Promise((resolve) => setTimeout(resolve, 25));
  assert.equal(receiptSent.some((message) => message.type === "session.error" && message.requestId === "request_receipt" && message.code === "receipt_timeout"), true);
});

test("Responses transport uses output_item.done once and requires response.completed", async () => {
  const sse = [
    `data: ${JSON.stringify({ type: "response.function_call_arguments.done", name: "propose_scene", arguments: proposal })}\n\n`,
    `data: ${JSON.stringify({ type: "response.output_item.done", item: { type: "function_call", name: "propose_scene", arguments: proposal } })}\n\n`,
    `data: ${JSON.stringify({ type: "response.completed" })}\n\n`
  ].join("");
  const transport = new OpenAIResponsesTransport("test", async () => new Response(sse, { status: 200 }));
  const events: ModelEvent[] = [];
  for await (const event of transport.stream({ requestId: "request_sse", text: "private", selectionNodeIds: [], scene: { nodes: [] }, signal: new AbortController().signal })) events.push(event);
  assert.deepEqual(events.map((event) => event.type), ["function_call", "done"]);

  const sent: JsonObject[] = [];
  const incomplete = new AstraSession(new ScriptedModel([{ type: "function_call", name: "propose_scene", arguments: proposal }]), { send: (message) => sent.push(message) });
  incomplete.acceptHello(hello); incomplete.updateSnapshot(snapshot);
  await incomplete.request({ type: "user.request", requestId: "request_incomplete", text: "show a server" });
  assert.equal(sent.some((message) => message.type === "generation.batch"), false);
  assert.equal(sent.some((message) => message.type === "session.error" && message.code === "model_incomplete"), true);
});

test("completed model streams are explicitly unwound before a response body EOF", async () => {
  let unwound = false;
  const model: ModelTransport = { async *stream(): AsyncIterable<ModelEvent> {
    try {
      yield { type: "function_call", name: "propose_scene", arguments: JSON.stringify({ mode: "explanation", explanation: "Done.", scopeParentNodeId: null, operations: [] }) };
      yield { type: "done" };
      await new Promise<void>(() => {});
    } finally { unwound = true; }
  }};
  const session = new AstraSession(model, { send: () => {} });
  session.acceptHello(hello); session.updateSnapshot(snapshot);
  await session.request({ type: "user.request", requestId: "request_release", text: "explain" });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(unwound, true);
});

test("Responses body is cancelled after response.completed arrives before EOF", async () => {
  let cancelled = false;
  let abortObserved = false;
  let streamController: ReadableStreamDefaultController<Uint8Array> | undefined;
  const encoder = new TextEncoder();
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      streamController = controller;
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "response.output_item.done", item: { type: "function_call", name: "propose_scene", arguments: JSON.stringify({ mode: "explanation", explanation: "Done.", scopeParentNodeId: null, operations: [] }) } })}\n\n`));
      controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "response.completed" })}\n\n`));
    },
    cancel() { cancelled = true; }
  });
  const transport = new OpenAIResponsesTransport("test", async (_url, init) => {
    (init?.signal as AbortSignal).addEventListener("abort", () => {
      abortObserved = true;
      streamController?.error(new DOMException("The operation was aborted.", "AbortError"));
    }, { once: true });
    return new Response(body, { status: 200 });
  });
  const session = new AstraSession(transport, { send: () => {} });
  session.acceptHello(hello); session.updateSnapshot(snapshot);
  await session.request({ type: "user.request", requestId: "request_response_body", text: "explain" });
  assert.equal(cancelled, true);
  assert.equal(abortObserved, true);
});

test("model input includes a selected node beyond the former 128-node cut-off", () => {
  const nodes = Array.from({ length: 179 }, (_, index) => ({ nodeId: `node_${index}` }));
  const input = formatUserInput({ requestId: "request_full_scene", text: "inspect selected", selectionNodeIds: ["node_178"], scene: { nodes }, signal: new AbortController().signal });
  const context = JSON.parse(input);
  assert.deepEqual(context.selectionNodeIds, ["node_178"]);
  assert.deepEqual(context.acceptedScene.scene.nodes, nodes);
});
