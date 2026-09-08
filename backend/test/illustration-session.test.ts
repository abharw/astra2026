import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { deflateSync } from "node:zlib";
import { ModelEvent, ModelRequest, ModelTransport } from "../src/astra/client.js";
import { AstraSession } from "../src/session.js";
import { JsonObject } from "../src/json.js";
import { IllustrationService, illustrationPrompt } from "../src/illustrations/jobs.js";
import { IllustrationArtifactStore } from "../src/illustrations/store.js";
import { IllustrationProvider } from "../src/illustrations/provider.js";
import { parseClientEnvelope } from "../src/protocol.js";
import { SessionServer } from "../src/server.js";

const hello = { type: "session.hello" as const, protocolVersion: 1, sessionId: "image-test", sceneId: "scene", revision: 0, intentEpoch: 1, sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: ["box.v1", "illustration.v1"] };
const snapshot = { type: "phone.snapshot" as const, sceneId: "scene", revision: 0, intentEpoch: 1, document: { nodes: [{ nodeId: "part", parentId: null, semantic: { name: "Lamp", role: "light", description: "A reading lamp." } }] } };
const intent = { brief: "Show the selected lamp's light direction.", componentNodeIds: ["part"], sourceArtifactId: null as string | null };
const turn = { type: "user.request" as const, requestId: "request-image", text: "Show a diagram" };

function proposal(illustration: typeof intent | null = intent): string { return JSON.stringify({ mode: "explanation", explanation: "I am preparing an illustration of this component.", scopeParentNodeId: null, operations: [], illustration }); }
function modelWith(getProposal: (request: ModelRequest) => string = () => proposal()): ModelTransport {
  return { async *stream(request): AsyncIterable<ModelEvent> { yield { type: "function_call", name: "propose_scene", arguments: getProposal(request) }; yield { type: "done" }; } };
}

async function harness(provider: IllustrationProvider, options: { model?: ModelTransport; timeoutMs?: number; service?: IllustrationService; capabilities?: string[] } = {}) {
  const directory = await mkdtemp(join(tmpdir(), "astra-image-session-"));
  const service = options.service ?? new IllustrationService(provider, new IllustrationArtifactStore({ directory }), options.timeoutMs);
  const sent: JsonObject[] = [];
  const session = new AstraSession(options.model ?? modelWith(), { send: message => sent.push(message) }, { illustrations: service });
  session.acceptHello({ ...hello, capabilities: options.capabilities ?? hello.capabilities }); session.updateSnapshot(snapshot);
  return { session, sent, service, directory, async close() { session.dispose(); await rm(directory, { recursive: true, force: true }); } };
}
function states(sent: JsonObject[]): JsonObject[] { return sent.filter(message => message.type === "illustration.state"); }
async function until(check: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) { if (check()) return; await new Promise(resolve => setTimeout(resolve, 5)); }
  assert.fail("Timed out waiting for illustration state");
}
function controlled() {
  const calls: { request: Parameters<IllustrationProvider["generate"]>[0]; resolve: (value: { bytes: Buffer; model: string }) => void }[] = [];
  const provider: IllustrationProvider = { generate(request) { return new Promise(resolve => calls.push({ request, resolve })); } };
  return { provider, calls, finish(index = 0, color = 255) { calls[index]!.resolve({ bytes: png(color), model: "gpt-image-2.5-flare" }); } };
}

test("image work returns the explanation immediately and survives an ordinary epoch supersession", async () => {
  const pending = controlled(); const h = await harness(pending.provider);
  try {
    await h.session.request(turn);
    assert.ok(h.sent.some(message => message.type === "session.explanation"));
    assert.deepEqual(states(h.sent).map(message => message.status), ["generating"]);
    assert.equal(h.sent.some(message => ["generation.begin", "generation.batch", "scene.patch"].includes(String(message.type))), false);
    await until(() => pending.calls.length === 1);
    h.session.fence("scene", 2); h.session.updateSnapshot({ ...snapshot, intentEpoch: 2 });
    assert.equal(pending.calls[0]!.request.signal.aborted, false);
    pending.finish(); await until(() => states(h.sent).at(-1)?.status === "ready");
    assert.equal(states(h.sent).at(-1)?.intentEpoch, 1);
    assert.equal(states(h.sent).at(-1)?.revision, 0);
  } finally { await h.close(); }
});

test("explicit cancellation beats a late provider; retry never replays model or mutation and preserves epoch", async () => {
  const pending = controlled(); let modelCalls = 0;
  const h = await harness(pending.provider, { model: modelWith(() => { modelCalls += 1; return proposal(); }) });
  try {
    await h.session.request(turn); await until(() => pending.calls.length === 1);
    const oldId = String(states(h.sent)[0]!.jobId);
    h.session.cancelIllustration(oldId);
    assert.equal(pending.calls[0]!.request.signal.aborted, true);
    h.session.fence("scene", 2); h.session.updateSnapshot({ ...snapshot, intentEpoch: 2 });
    h.session.retryIllustration(oldId); h.session.retryIllustration(oldId);
    const retry = states(h.sent).at(-1)!;
    assert.notEqual(retry.jobId, oldId); assert.equal(retry.intentEpoch, 1);
    assert.equal(modelCalls, 1);
    await until(() => pending.calls.length === 2);
    pending.finish(0); await new Promise(resolve => setImmediate(resolve));
    assert.equal(states(h.sent).some(message => message.status === "ready"), false);
    pending.finish(1); await until(() => states(h.sent).at(-1)?.status === "ready");
    assert.equal(states(h.sent).at(-1)?.jobId, retry.jobId);
    assert.equal(h.sent.filter(message => message.type === "session.explanation").length, 1);
  } finally { await h.close(); }
});

test("Stop during retry admission can cancel through the previous job ID", async () => {
  const pending = controlled(); const h = await harness(pending.provider);
  try {
    await h.session.request(turn); await until(() => pending.calls.length === 1);
    const oldId = String(states(h.sent)[0]!.jobId);
    h.session.cancelIllustration(oldId); h.session.retryIllustration(oldId); h.session.cancelIllustration(oldId);
    assert.deepEqual(states(h.sent).map(message => message.status), ["generating", "cancelled", "generating", "cancelled"]);
    pending.finish();
  } finally { await h.close(); }
});

test("document changes without revision changes fence provider completion and reject retry", async () => {
  const pending = controlled(); const h = await harness(pending.provider);
  try {
    await h.session.request(turn); await until(() => pending.calls.length === 1);
    const jobId = String(states(h.sent)[0]!.jobId);
    h.session.updateSnapshot({ ...snapshot, document: { nodes: [] } });
    pending.finish(); await new Promise(resolve => setImmediate(resolve));
    assert.equal(states(h.sent).at(-1)?.status, "stale");
    assert.equal(states(h.sent).some(message => message.status === "ready"), false);
    assert.throws(() => h.session.retryIllustration(jobId), /retained failed or cancelled/);
  } finally { await h.close(); }
});

test("scene receipt immediately invalidates a ready panel before the new document snapshot", async () => {
  const h = await harness({ async generate() { return { bytes: png(), model: "gpt-image-2.5-flare" }; } });
  try {
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "ready");
    h.session.receiveReceipt({ type: "scene.receipt", protocolVersion: 1, sceneId: "scene", requestId: "installed-other", status: "installed", revision: 1, affectedNodeIds: ["part"] });
    assert.equal(states(h.sent).at(-1)?.status, "stale");
    await h.session.request({ ...turn, requestId: "during-gap" });
    assert.ok(h.sent.some(message => message.type === "session.error" && message.code === "scene_snapshot_pending"));
    assert.equal(states(h.sent).filter(message => message.status === "generating").length, 1);
  } finally { await h.close(); }
});

test("retry is rejected in receipt-to-snapshot gap and after revision change", async () => {
  const h = await harness({ async generate() { throw new Error("provider failed"); } });
  try {
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "failed");
    const jobId = String(states(h.sent)[0]!.jobId);
    h.session.receiveGenerationReceipt({ type: "generation.receipt", protocolVersion: 1, sceneId: "scene", generationId: "other", requestId: "other:finish", status: "completed", revision: 1, committedSequence: 1 });
    assert.throws(() => h.session.retryIllustration(jobId), /source scene changed/);
    h.session.updateSnapshot({ ...snapshot, revision: 1 });
    assert.throws(() => h.session.retryIllustration(jobId), /source scene changed/);
  } finally { await h.close(); }
});

test("an obsolete failed job cannot replace the newer generating illustration", async () => {
  const pending = controlled(); let calls = 0;
  const h = await harness({ generate(request) { calls += 1; if (calls === 1) return Promise.reject(new Error("failed")); return pending.provider.generate(request); } });
  try {
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "failed");
    const oldId = String(states(h.sent)[0]!.jobId);
    await h.session.request({ ...turn, requestId: "replacement" }); await until(() => pending.calls.length === 1);
    const newId = states(h.sent).at(-1)!.jobId;
    assert.throws(() => h.session.retryIllustration(oldId), /newer illustration replaced/);
    assert.equal(pending.calls[0]!.request.signal.aborted, false);
    pending.finish(); await until(() => states(h.sent).at(-1)?.status === "ready");
    assert.equal(states(h.sent).at(-1)?.jobId, newId); assert.equal(calls, 2);
  } finally { await h.close(); }
});

test("receipt revision without its document cannot admit model work that a later snapshot would authorize", async () => {
  let modelCalls = 0;
  const h = await harness({ async generate() { throw new Error("not requested"); } }, { model: modelWith(() => { modelCalls += 1; return proposal(null); }) });
  try {
    h.session.receiveReceipt({ type: "scene.receipt", protocolVersion: 1, sceneId: "scene", requestId: "other", status: "installed", revision: 1, affectedNodeIds: ["part"] });
    const request = h.session.request(turn);
    h.session.updateSnapshot({ ...snapshot, revision: 1, document: { nodes: [{ nodeId: "part", semantic: { name: "Changed component" } }] } });
    await request;
    assert.equal(modelCalls, 0);
    assert.ok(h.sent.some(message => message.type === "session.error" && message.code === "scene_snapshot_pending"));
    await h.session.request({ ...turn, requestId: "synchronized-request" }); assert.equal(modelCalls, 1);
  } finally { await h.close(); }
});

test("new image admission replaces only the image job and disconnect suppresses late results", async () => {
  const pending = controlled(); const h = await harness(pending.provider);
  try {
    await h.session.request(turn); await until(() => pending.calls.length === 1);
    await h.session.request({ ...turn, requestId: "new-image" }); await until(() => pending.calls.length === 2);
    assert.equal(pending.calls[0]!.request.signal.aborted, true);
    assert.deepEqual(states(h.sent).map(message => message.status), ["generating", "cancelled", "generating"]);
    const before = h.sent.length; h.session.dispose(); pending.finish(0); pending.finish(1);
    await new Promise(resolve => setTimeout(resolve, 20)); assert.equal(h.sent.length, before);
  } finally { await h.close(); }
});

test("identical admitted context reuses cached PNG without a second provider call", async () => {
  let count = 0;
  const h = await harness({ async generate() { count += 1; return { bytes: png(), model: "gpt-image-2.5-flare" }; } });
  try {
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "ready");
    const first = states(h.sent).at(-1)!;
    h.session.fence("scene", 2); h.session.updateSnapshot({ ...snapshot, intentEpoch: 2 });
    await h.session.request({ ...turn, requestId: "same-image" }); await until(() => states(h.sent).filter(message => message.status === "ready").length === 2);
    assert.equal(count, 1); assert.equal(states(h.sent).at(-1)?.cacheHit, true);
    assert.deepEqual(states(h.sent).at(-1)?.artifact, first.artifact);
  } finally { await h.close(); }
});

test("refinement receives the retained PNG and bounded metadata, with source authorization at request admission", async () => {
  const requests: Parameters<IllustrationProvider["generate"]>[0][] = []; const modelRequests: ModelRequest[] = [];
  const h = await harness({ async generate(request) { requests.push(request); return { bytes: png(requests.length), model: "gpt-image-2.5-flare" }; } }, { model: modelWith(request => {
    modelRequests.push(request);
    return proposal({ ...intent, brief: request.requestId === turn.requestId ? intent.brief : "Keep the layout and simplify the labels.", sourceArtifactId: request.recentIllustrations?.at(-1)?.artifactId ?? null });
  }) });
  try {
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "ready");
    await h.session.request({ ...turn, requestId: "refinement" }); await until(() => states(h.sent).filter(message => message.status === "ready").length === 2);
    assert.equal(requests.length, 2); assert.equal(requests[0]!.source, undefined);
    assert.deepEqual(requests[1]!.source?.bytes, png(1));
    assert.equal(modelRequests[1]!.recentIllustrations?.length, 1);
    assert.ok(requests[1]!.prompt.includes("Refine the supplied previous illustration"));
    const refinement = states(h.sent).at(-1)!.artifact as JsonObject;
    assert.equal(refinement.sourceArtifactId, modelRequests[1]!.recentIllustrations![0]!.artifactId);
  } finally { await h.close(); }
});

test("illustration requires negotiated capability and does not leak into a legacy session", async () => {
  let providerCalls = 0; let capability: boolean | undefined;
  const h = await harness({ async generate() { providerCalls += 1; return { bytes: png(), model: "gpt-image-2.5-flare" }; } }, { capabilities: ["box.v1"], model: modelWith(request => { capability = request.illustrationEnabled; return proposal(); }) });
  try {
    await h.session.request(turn);
    assert.equal(capability, false); assert.equal(providerCalls, 0); assert.equal(states(h.sent).length, 0);
    assert.equal(h.sent[0]!.illustrationEnabled, false);
    assert.ok(h.sent.some(message => message.code === "illustration_unavailable"));
  } finally { await h.close(); }
});

test("a fabricated or cross-scene source artifact never reaches the image provider", async () => {
  let count = 0;
  const h = await harness({ async generate() { count += 1; return { bytes: png(), model: "gpt-image-2.5-flare" }; } }, { model: modelWith(() => proposal({ ...intent, sourceArtifactId: `sha256:${"a".repeat(64)}` })) });
  try {
    await h.session.request(turn); assert.equal(count, 0);
    assert.ok(h.sent.some(message => message.code === "illustration_source_unavailable"));
  } finally { await h.close(); }
});

test("independent deadline fails truthfully and fences an abort-ignoring provider", async () => {
  const pending = controlled(); const h = await harness(pending.provider, { timeoutMs: 15 });
  try {
    await h.session.request(turn); await until(() => pending.calls.length === 1);
    await until(() => states(h.sent).at(-1)?.status === "failed");
    assert.match(String(states(h.sent).at(-1)?.error), /took too long/);
    pending.finish(); await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(states(h.sent).some(message => message.status === "ready"), false);
  } finally { await h.close(); }
});

test("deadline terminates the visible job even while a disk lookup is delayed", async () => {
  const directory = await mkdtemp(join(tmpdir(), "astra-image-delayed-store-"));
  class SlowStore extends IllustrationArtifactStore {
    override async lookup(key: string) { await new Promise(resolve => setTimeout(resolve, 35)); return super.lookup(key); }
  }
  let providerCalls = 0;
  const provider = { async generate() { providerCalls += 1; return { bytes: png(), model: "gpt-image-2.5-flare" }; } };
  const h = await harness(provider, { service: new IllustrationService(provider, new SlowStore({ directory }), 10) });
  try {
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "failed");
    await new Promise(resolve => setTimeout(resolve, 45));
    assert.deepEqual(states(h.sent).map(message => message.status), ["generating", "failed"]);
    assert.equal(providerCalls, 0);
  } finally { await h.close(); await rm(directory, { recursive: true, force: true }); }
});

test("refinement cannot rebind a retained image to an unrelated scene component", async () => {
  let calls = 0;
  const h = await harness({ async generate() { calls += 1; return { bytes: png(), model: "gpt-image-2.5-flare" }; } }, { model: modelWith(request => proposal(request.requestId === turn.requestId ? intent : { ...intent, componentNodeIds: ["other-part"], sourceArtifactId: request.recentIllustrations![0]!.artifactId })) });
  try {
    h.session.updateSnapshot({ ...snapshot, document: { nodes: [...snapshot.document.nodes, { nodeId: "other-part", parentId: null, semantic: { name: "Telescope" } }] } });
    await h.session.request(turn); await until(() => states(h.sent).at(-1)?.status === "ready");
    await h.session.request({ ...turn, requestId: "wrong-component-refinement" });
    assert.equal(calls, 1); assert.ok(h.sent.some(message => message.code === "illustration_source_unavailable"));
  } finally { await h.close(); }
});

test("source image authority is fixed before authoring and cannot expand while a model runs", async () => {
  const pending = controlled(); let resume: ((value: string) => void) | undefined;
  const model: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> {
    const argumentsText = request.requestId === turn.requestId ? proposal() : await new Promise<string>(resolve => { resume = resolve; });
    yield { type: "function_call", name: "propose_scene", arguments: argumentsText }; yield { type: "done" };
  } };
  const h = await harness(pending.provider, { model });
  try {
    await h.session.request(turn); await until(() => pending.calls.length === 1);
    const second = h.session.request({ ...turn, requestId: "began-before-ready" });
    await until(() => Boolean(resume)); pending.finish(); await until(() => states(h.sent).at(-1)?.status === "ready");
    const sourceArtifactId = String((states(h.sent).at(-1)!.artifact as JsonObject).artifactId);
    resume!(proposal({ ...intent, sourceArtifactId })); await second;
    assert.equal(pending.calls.length, 1);
    assert.ok(h.sent.some(message => message.code === "illustration_source_unavailable"));
  } finally { await h.close(); }
});

test("global concurrency stays at two while a cancelled provider is still settling", async () => {
  const pending = controlled(); const first = await harness(pending.provider);
  const second = await harness(pending.provider, { service: first.service }); const third = await harness(pending.provider, { service: first.service });
  try {
    await first.session.request(turn); await second.session.request(turn); await until(() => pending.calls.length === 2);
    first.session.cancelIllustration(String(states(first.sent)[0]!.jobId));
    await third.session.request(turn); await until(() => states(third.sent).at(-1)?.status === "failed");
    assert.equal(pending.calls.length, 2); assert.match(String(states(third.sent).at(-1)?.error), /busy/);
    pending.finish(0); pending.finish(1); await until(() => states(second.sent).at(-1)?.status === "ready");
  } finally { await Promise.all([first.close(), second.close(), third.close()]); }
});

test("wire image controls are exact and reject extra fields", () => {
  assert.deepEqual(parseClientEnvelope({ type: "illustration.cancel", jobId: "image" }), { type: "illustration.cancel", jobId: "image" });
  assert.deepEqual(parseClientEnvelope({ type: "illustration.retry", jobId: "image" }), { type: "illustration.retry", jobId: "image" });
  assert.throws(() => parseClientEnvelope({ type: "illustration.retry", jobId: "image", scene: {} }), /unknown property/);
});

test("artifact route requires authentication and returns exact validated immutable PNG bytes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "astra-image-http-"));
  const store = new IllustrationArtifactStore({ directory });
  const artifact = await store.put({ bytes: png(), model: "gpt-image-2.5-flare", sourceRevision: 0, cacheKey: "key", provenance: { sceneId: "scene" } });
  const server = new SessionServer({ host: "127.0.0.1", port: 0, model: modelWith(), accessToken: "private-session-token", illustrationDirectory: directory, illustrationProvider: { async generate() { throw new Error("unexpected generation"); } }, logger: { log() {} } });
  await server.listen();
  try {
    assert.equal((await fetch(`${server.address()}${artifact.path}`)).status, 401);
    const headers = { authorization: "Bearer private-session-token" };
    assert.equal((await fetch(`${server.address()}${artifact.path}`, { headers: { authorization: "Bearer wrong-token" } })).status, 401);
    const response = await fetch(`${server.address()}${artifact.path}`, { headers });
    assert.equal(response.status, 200); assert.equal(response.headers.get("content-type"), "image/png");
    assert.equal(response.headers.get("etag"), `"${artifact.artifactId}"`);
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), png());
    assert.equal((await fetch(`${server.address()}/illustrations/artifacts/${"0".repeat(64)}.png`, { headers })).status, 404);
    assert.equal((await fetch(`${server.address()}/illustrations/artifacts/not-a-hash.png`, { headers })).status, 404);
  } finally { await server.close(); await rm(directory, { recursive: true, force: true }); }
});

test("illustration prompt uses admitted generic semantics with a finite context budget", () => {
  const nodes = Array.from({ length: 300 }, (_, index) => ({ nodeId: index ? `child-${index}` : "part", parentId: index ? "part" : null, semantic: { name: "Light", description: "💡".repeat(1000) } }));
  const prompt = illustrationPrompt({ nodes }, intent);
  assert.ok(prompt.includes("Light")); assert.ok(prompt.includes("part"));
  assert.ok(Buffer.byteLength(prompt) < 20_000); assert.equal(prompt.includes("child-299"), false);
});

test("context budget preserves all sixteen selected identities and UTF-8 names before ancestors", () => {
  const nodes = Array.from({ length: 16 }, (_, index) => ({ nodeId: `part-${index}`, parentId: null, semantic: { name: `Light${index} ${"灯".repeat(250)}`, role: "灯".repeat(128), description: "灯".repeat(384) } }));
  const prompt = illustrationPrompt({ nodes }, { ...intent, componentNodeIds: nodes.map(node => node.nodeId) });
  for (const node of nodes) { assert.ok(prompt.includes(`"nodeId":"${node.nodeId}"`)); assert.ok(prompt.includes(node.semantic.name.slice(0, 10))); }
  assert.ok(Buffer.byteLength(prompt) < 20_000);
});

test("context byte budget includes JSON escapes while retaining every selected identity", () => {
  const nodes = Array.from({ length: 16 }, (_, index) => ({ nodeId: `part-${index}${"\u0001".repeat(120)}`, parentId: `parent${"\u0001".repeat(120)}`, semantic: { name: `Light${index}${"\u0001\\\"".repeat(200)}`, role: "\u0001".repeat(128), description: "\u0001".repeat(384) } }));
  const prompt = illustrationPrompt({ nodes }, { ...intent, componentNodeIds: nodes.map(node => node.nodeId) });
  const contextText = prompt.split("Accepted component context: ")[1]!;
  assert.ok(Buffer.byteLength(contextText) <= 16_384);
  const context = JSON.parse(contextText) as JsonObject[];
  assert.deepEqual(new Set(context.map(node => node.nodeId)), new Set(nodes.map(node => node.nodeId)));
  assert.ok(context.every(node => typeof node.name === "string" && node.name.startsWith("Light")));
});

function png(red = 255): Buffer {
  const header = Buffer.alloc(13); header.writeUInt32BE(1, 0); header.writeUInt32BE(1, 4); header[8] = 8; header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(Buffer.from([0, red, 0, 0, 255]))), chunk("IEND", Buffer.alloc(0))]);
}
function chunk(type: string, payload: Buffer): Buffer {
  const bytes = Buffer.alloc(payload.length + 12); bytes.writeUInt32BE(payload.length, 0); bytes.write(type, 4, "ascii"); payload.copy(bytes, 8);
  let crc = 0xffffffff; for (const byte of bytes.subarray(4, bytes.length - 4)) { crc ^= byte; for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length - 4); return bytes;
}
