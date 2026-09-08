import assert from "node:assert/strict";
import test from "node:test";
import { ModelEvent, ModelRequest, ModelTransport } from "../src/astra/client.js";
import { RecentTurn } from "../src/astra/conversation-context.js";
import { JsonObject } from "../src/json.js";
import { PhoneSnapshot, SceneReceipt, SessionHello } from "../src/protocol.js";
import { AstraSession, SessionOptions } from "../src/session.js";

const sceneId = "scene_continuity";
const hello: SessionHello = {
  type: "session.hello", protocolVersion: 1, sessionId: "continuity_test", sceneId,
  revision: 0, intentEpoch: 1, sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: ["box.v1"]
};

function document(serverZ = 0, includeArrow = true): JsonObject {
  const node = (nodeId: string, z: number): JsonObject => ({
    nodeId, parentId: null, geometryId: null, materialId: null, isVisible: true,
    transform: { translation: [0, 0, z], rotation: [0, 0, 0, 1], scale: [1, 1, 1] },
    semantic: { name: nodeId }, provenance: { origin: "imported", factualSupport: "referenceBased", sourceRefs: [] }
  });
  return { sceneId, nodes: [node("server01", serverZ), node("server02", 0), ...(includeArrow ? [node("arrow01", 0)] : [])], geometryDefinitions: [], materialDefinitions: [] };
}

function snapshot(revision = 0, intentEpoch = 1, serverZ = 0, includeArrow = true): PhoneSnapshot {
  return { type: "phone.snapshot", sceneId, revision, intentEpoch, document: document(serverZ, includeArrow) };
}

function explanation(text = "The selected server contains the compute hardware."): string {
  return JSON.stringify({ mode: "explanation", explanation: text, scopeParentNodeId: null, operations: [] });
}

function patch(): string {
  return JSON.stringify({ mode: "patch", explanation: "The server is moved forward for inspection.", scopeParentNodeId: null,
    operations: [{ kind: "setTransform", nodeRef: "server01", transform: { translation: [0, 0, 0.4], rotation: [0, 0, 0, 1], scale: [1, 1, 1] } }]
  });
}

type CapturedRequest = Pick<ModelRequest, "requestId" | "text" | "selectionNodeIds" | "scene" | "recentTurns">;
type ModelScript = (request: ModelRequest) => AsyncIterable<ModelEvent>;

class CapturingModel implements ModelTransport {
  readonly requests: CapturedRequest[] = [];
  readonly scripts: ModelScript[] = [];

  async *stream(request: ModelRequest): AsyncIterable<ModelEvent> {
    this.requests.push(structuredClone({ requestId: request.requestId, text: request.text, selectionNodeIds: request.selectionNodeIds, scene: request.scene, recentTurns: request.recentTurns }));
    const script = this.scripts.shift();
    if (script) { yield* script(request); return; }
    yield* events(explanation());
  }

  enqueue(proposal: string): void { this.scripts.push(async function* () { yield* events(proposal); }); }
}

function* events(proposal: string): Iterable<ModelEvent> {
  yield { type: "function_call", name: "propose_scene", arguments: proposal };
  yield { type: "done" };
}

function fixture(options: SessionOptions = {}) {
  const model = new CapturingModel();
  const sent: JsonObject[] = [];
  const session = new AstraSession(model, { send: (message) => sent.push(message) }, options);
  session.acceptHello(hello);
  session.updateSnapshot(snapshot());
  const ask = (requestId: string, text: string, ids?: string[]) => session.request({ type: "user.request", requestId, text, ...(ids ? { selection: { nodeIds: ids } } : {}) });
  return { model, sent, session, ask };
}

function receipt(requestId: string, status: "installed" | "rejected" = "installed", revision = 1): SceneReceipt {
  return { type: "scene.receipt", protocolVersion: 1, sceneId, requestId: `${requestId}:patch`, status, revision, affectedNodeIds: ["server01", "arrow01"] };
}

function recent(request: CapturedRequest | undefined): RecentTurn[] { assert.ok(request); return request.recentTurns ?? []; }
const tick = () => new Promise<void>((resolve) => setImmediate(resolve));

test("answered follow-ups retain previous scope while an explicit new selection stays authoritative", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  await ask("explain_first", "Explain this server", ["server01"]);
  await ask("explain_followup", "What about its cooling?");
  assert.deepEqual(recent(model.requests[1]), [{
    userRequest: "Explain this server", selectionNodeIds: ["server01"],
    result: { status: "answered", explanation: "The selected server contains the compute hardware.", affectedNodeIds: [] }
  }]);
  assert.deepEqual(model.requests[1]?.selectionNodeIds, []);
  await ask("different_selection", "Explain this one instead", ["server02"]);
  assert.deepEqual(model.requests[2]?.selectionNodeIds, ["server02"]);
  assert.deepEqual(recent(model.requests[2])[0]?.selectionNodeIds, ["server01"]);
});

test("installed history requires the matching native receipt and never supplies an obsolete scene pose", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  model.enqueue(patch());
  await ask("move_server", "Move this server forward", ["server01"]);
  await ask("before_receipt", "What has happened?");
  assert.deepEqual(recent(model.requests[1]), []);
  session.receiveReceipt({ ...receipt("unrelated"), revision: 0 });
  await ask("after_wrong_receipt", "Is it installed?");
  assert.equal(recent(model.requests[2]).some((turn) => turn.result.status === "installed"), false);
  session.receiveReceipt(receipt("move_server"));
  session.updateSnapshot(snapshot(1, 1, 0.4));
  await ask("after_receipt", "Explain it now");
  const request = model.requests[3]!;
  const installed = recent(request).find((turn) => turn.result.status === "installed");
  assert.ok(installed);
  assert.equal(installed.userRequest, "Move this server forward");
  assert.deepEqual(installed.selectionNodeIds, ["server01"]);
  assert.deepEqual(installed.result.affectedNodeIds, ["server01", "arrow01"]);
  assert.deepEqual(Object.keys(installed).sort(), ["result", "selectionNodeIds", "userRequest"]);
  assert.deepEqual(request.scene, document(0.4));
  assert.equal(JSON.stringify(installed).includes("transform"), false);
});

test("undo fences leave the current snapshot authoritative and prune removed historical targets", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  model.enqueue(patch());
  await ask("move_then_undo", "Move this server", ["server01", "arrow01"]);
  session.receiveReceipt(receipt("move_then_undo"));
  session.updateSnapshot(snapshot(1, 1, 0.4));
  session.fence(sceneId, 2);
  session.updateSnapshot(snapshot(2, 2, 0, false));
  await ask("after_undo", "Where is it now?");
  const request = model.requests[1]!;
  assert.deepEqual(request.scene, document(0, false));
  const previous = recent(request)[0]!;
  assert.equal(previous.result.status, "installed");
  assert.deepEqual(previous.selectionNodeIds, ["server01"]);
  assert.deepEqual(previous.result.affectedNodeIds, ["server01"]);
  assert.equal(JSON.stringify(previous).includes("translation"), false);
});

test("a new scene and a fresh connection do not inherit previous conversation outcomes", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  await ask("old_scene_question", "Explain this", ["server01"]);
  session.acceptHello({ ...hello, sceneId: "scene_new" });
  session.updateSnapshot({ ...snapshot(), sceneId: "scene_new", document: { nodes: [] } });
  await ask("new_scene_question", "What is here?");
  assert.deepEqual(recent(model.requests[1]), []);
  session.dispose();
  const newConnection = fixture(); t.after(() => newConnection.session.dispose());
  await newConnection.ask("fresh_connection", "What were we discussing?");
  assert.deepEqual(recent(newConnection.model.requests[0]), []);
});

test("explicit device rejection is remembered as failed and never as installed", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  model.enqueue(patch());
  await ask("rejected_move", "Move this server", ["server01"]);
  session.receiveReceipt(receipt("rejected_move", "rejected", 0));
  await ask("after_rejection", "What changed?");
  assert.deepEqual(recent(model.requests[1]), [{
    userRequest: "Move this server", selectionNodeIds: ["server01"],
    result: { status: "failed", explanation: "The device rejected the proposed scene change.", affectedNodeIds: [] }
  }]);
});

test("a provider failure before delivery is a failed outcome with no affected nodes", async (t) => {
  const { model, session, sent, ask } = fixture(); t.after(() => session.dispose());
  model.scripts.push(async function* () { throw new Error("provider disconnected"); });
  await ask("failed_model", "Move this server", ["server01"]);
  assert.equal(sent.some((message) => message.type === "scene.patch"), false);
  await ask("after_failure", "What changed?");
  assert.equal(recent(model.requests[1])[0]?.result.status, "failed");
  assert.deepEqual(recent(model.requests[1])[0]?.result.affectedNodeIds, []);
});

test("cancelled model work and fenced unconfirmed proposals never become conversation outcomes", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  model.scripts.push(async function* (request) {
    await new Promise<void>((resolve) => request.signal.addEventListener("abort", () => resolve(), { once: true }));
  });
  const cancelled = ask("cancel_during_model", "Move this server", ["server01"]);
  await tick();
  session.cancel("cancel_during_model");
  await cancelled;
  model.enqueue(patch());
  await ask("cancel_after_delivery", "Move this server", ["server01"]);
  assert.deepEqual(recent(model.requests[1]), []);
  session.fence(sceneId, 2);
  session.updateSnapshot(snapshot(0, 2));
  session.receiveReceipt(receipt("cancel_after_delivery", "installed", 0));
  await ask("after_cancellations", "What changed?");
  assert.deepEqual(recent(model.requests[2]), []);
});

test("receipt timeout omits unconfirmed work, including a receipt arriving after expiry", async (t) => {
  const { model, session, sent, ask } = fixture({ receiptTimeoutMs: 5 }); t.after(() => session.dispose());
  model.enqueue(patch());
  await ask("receipt_expired", "Move this server", ["server01"]);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(sent.some((message) => message.code === "receipt_timeout"));
  session.receiveReceipt(receipt("receipt_expired", "installed", 0));
  await ask("after_expiry", "Did it happen?");
  assert.deepEqual(recent(model.requests[1]), []);
});

test("model timeout is omitted instead of becoming a failed or installed historical claim", async (t) => {
  const { model, session, sent, ask } = fixture({ modelTimeoutMs: 5 }); t.after(() => session.dispose());
  model.scripts.push(async function* (request) {
    await new Promise<void>((resolve) => request.signal.addEventListener("abort", () => resolve(), { once: true }));
  });
  const deadline = new Promise((resolve) => setTimeout(resolve, 20));
  await ask("model_expired", "Move this server", ["server01"]);
  await deadline;
  assert.ok(sent.some((message) => message.code === "model_timeout"));
  await ask("after_model_expiry", "Did it happen?");
  assert.deepEqual(recent(model.requests[1]), []);
});

test("cancelling a delivered proposal prevents a late receipt from creating installed history", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  model.enqueue(patch());
  await ask("cancel_pending", "Move this server", ["server01"]);
  session.cancel("cancel_pending");
  session.receiveReceipt(receipt("cancel_pending", "installed", 0));
  await ask("after_pending_cancel", "What changed?");
  assert.deepEqual(recent(model.requests[1]), []);
});

test("new-scene handshake invalidates proposals still awaiting the previous scene's receipt", async (t) => {
  const { model, session, ask } = fixture(); t.after(() => session.dispose());
  model.enqueue(patch());
  await ask("old_pending", "Move this server", ["server01"]);
  session.acceptHello({ ...hello, sceneId: "scene_new" });
  session.updateSnapshot({ ...snapshot(), sceneId: "scene_new" });
  // A matching request ID alone must not revive work owned by another scene.
  session.receiveReceipt({ ...receipt("old_pending", "installed", 0), sceneId: "scene_new" });
  await ask("after_scene_switch", "What changed?");
  assert.deepEqual(recent(model.requests[1]), []);
});
