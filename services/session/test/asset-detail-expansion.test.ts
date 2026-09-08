import assert from "node:assert/strict";
import test from "node:test";
import { AvailableAssetDetail } from "../src/asset-details.js";
import { ModelEvent, ModelRequest, ModelTransport, formatUserInput } from "../src/astra/client.js";
import { JsonObject, ProtocolError, asObject } from "../src/json.js";
import { AuthoringProposal, detailNodeId, geometryContentHash, normalizeProposal, payloadHash } from "../src/normalizer.js";
import { AstraSession } from "../src/session.js";
import { PhoneSnapshot, parseClientEnvelope } from "../src/protocol.js";

const pose = { translation: [1.25, -0.4, 2], rotation: [0, 0, Math.SQRT1_2, Math.SQRT1_2], scale: [0.7, 1.2, 0.7] };
const source = { origin: "imported", factualSupport: "referenceBased", sourceRefs: ["https://example.test/optics/drawing"] };
const detail: AvailableAssetDetail = {
  detailId: "optic.assembly-detail", targetNodeIds: ["optic.left", "optic.right"], name: "Lens assembly", description: "Immediate mechanical and optical parts.",
  assetID: `sha256:${"a".repeat(64)}`, byteCount: 4_096, triangleCount: 192,
  children: [
    { partID: "retaining-ring", transform: { translation: [0, 0, 0.02], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }, semantic: { name: "Retaining ring", role: "mechanical retention" }, provenance: source },
    { partID: "lens", transform: { translation: [0, 0, -0.01], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }, semantic: { name: "Lens", role: "refraction" }, provenance: source }
  ]
};
const nodes = new Map<string, JsonObject>([
  ["optic.left", { nodeId: "optic.left", geometryId: "optic-exterior", materialId: "finish", transform: pose, isVisible: false, semantic: { name: "Left optical assembly" } }],
  ["optic.right", { nodeId: "optic.right", geometryId: "optic-exterior", transform: { ...pose, translation: [-1, 0, 0] } }],
  ["optic.annotation", { nodeId: "optic.annotation", parentId: "optic.left", geometryId: "marker", transform: pose }]
]);
function proposal(operations: JsonObject[]): AuthoringProposal { return { mode: "patch", explanation: "Reveal this assembly's sourced immediate parts.", scopeParentNodeId: null, operations }; }
function expand(target = "optic.left"): JsonObject { return { kind: "expandDetail", nodeRef: target, detailId: detail.detailId }; }
function normalize(operations: JsonObject[], catalog = [detail], observed = nodes) {
  return normalizeProposal("request.detail", proposal(operations), new Set(observed.keys()), new Set(["optic-exterior", "marker"]), observed, catalog);
}
const rejected = (error: unknown) => error instanceof ProtocolError && error.code === "proposal_rejected";

test("one generic expansion retains a moved, rotated and scaled instance and every existing child edge", () => {
  const before = structuredClone([...nodes]);
  const normalized = normalize([expand()]);
  assert.deepEqual(normalized.operations.slice(0, 2), [
    { op: "set.geometry", nodeId: "optic.left", geometryId: null },
    { op: "set.material", nodeId: "optic.left", materialId: null }
  ]);
  const children = normalized.operations.filter((op) => op.op === "create.node").map((op) => asObject(op.node, "node"));
  assert.equal(children.length, 2);
  for (const [index, child] of children.entries()) {
    assert.equal(child.parentId, "optic.left");
    assert.equal(child.nodeId, detailNodeId("optic.left", detail.detailId, detail.children[index]!.partID));
    assert.deepEqual(child.transform, detail.children[index]!.transform);
    assert.deepEqual(child.provenance, source);
    assert.equal(child.materialId, null);
  }
  assert.equal(normalized.operations.some((op) => op.op === "set.transform" || op.op === "set.visibility" || op.op === "remove.node"), false);
  assert.equal(normalized.operations.some((op) => op.nodeId === "optic.right" || op.nodeId === "optic.annotation"), false);
  assert.deepEqual([...nodes], before, "normalization must not mutate the admitted snapshot");
  const geometry = asObject(normalized.operations[2]!.geometry, "geometry");
  assert.equal(geometry.contentHash, geometryContentHash(asObject(geometry.recipe, "recipe")));
  const patch: JsonObject = { type: "scene.patch", protocolVersion: 1, requestId: "request.detail:patch", sceneId: "scene.optic", intentEpoch: 7, baseRevision: 3, operations: normalized.operations };
  assert.match(payloadHash(patch), /^[a-f0-9]{64}$/);
});

test("coarse translation never expands or loads detail and expansion retains a same-turn parent move", () => {
  const move = { kind: "translate", nodeRef: "optic.left", offset: [0, 0, 0.2] };
  const coarse = normalize([move]);
  assert.equal(coarse.operations.length, 1);
  assert.equal(coarse.operations[0]!.op, "set.transform");
  const expanded = normalize([move, expand()]);
  assert.deepEqual(expanded.operations[0], coarse.operations[0]);
  assert.equal(expanded.operations.filter((op) => op.op === "set.transform").length, 1);
});

test("instances share immutable imported geometry while detail child identities are instance-scoped and stable across turns", () => {
  const normalized = normalize([expand("optic.left"), expand("optic.right")]);
  assert.equal(normalized.operations.filter((op) => op.op === "put.geometry").length, 2);
  const children = normalized.operations.filter((op) => op.op === "create.node").map((op) => asObject(op.node, "node"));
  assert.equal(new Set(children.map((child) => child.nodeId)).size, 4);
  assert.equal(children[0]!.geometryId, children[2]!.geometryId);
  const anotherTurn = normalizeProposal("other.request", proposal([expand()]), new Set(nodes.keys()), new Set(), nodes, [detail]);
  assert.deepEqual(anotherTurn.operations, normalize([expand()]).operations);
});

test("unadvertised, repeated and colliding expansions are rejected before delivery", () => {
  assert.throws(() => normalize([expand()], []), rejected);
  assert.throws(() => normalize([{ ...expand(), detailId: "made.up" }]), rejected);
  assert.throws(() => normalize([{ ...expand(), nodeRef: "optic.annotation" }]), rejected);
  assert.throws(() => normalize([expand(), expand()]), rejected);
  assert.throws(() => normalize([{ kind: "setGeometry", nodeRef: "optic.left", geometryAlias: null }, expand()]), rejected);
  assert.throws(() => normalize([expand(), { kind: "setGeometry", nodeRef: "optic.left", geometryAlias: "optic-exterior" }]), rejected);
  const collision = new Map(nodes);
  const collidingId = detailNodeId("optic.left", detail.detailId, "lens");
  collision.set(collidingId, { nodeId: collidingId, parentId: "unrelated" });
  assert.throws(() => normalize([expand()], [detail], collision), rejected);
  const alreadyExpanded = new Map(nodes);
  alreadyExpanded.set("optic.left", { ...nodes.get("optic.left")!, geometryId: null });
  assert.throws(() => normalize([expand()], [detail], alreadyExpanded), rejected);
  assert.throws(() => normalizeProposal("generation", { ...proposal([expand()]), mode: "generation" }, new Set(nodes.keys()), new Set(), nodes, [detail]), rejected);
});

test("expansion enforces the normalized wire-operation budget after shared-geometry factoring", () => {
  const largeDetail = { ...detail, targetNodeIds: ["optic.left", "optic.right", "optic.third"], children: Array.from({ length: 32 }, (_, index) => ({ ...detail.children[0]!, partID: `part.${index}` })) };
  const observed = new Map(nodes);
  observed.set("optic.third", { ...nodes.get("optic.left")!, nodeId: "optic.third" });
  assert.equal(normalize([expand("optic.left"), expand("optic.right")], [largeDetail], observed).operations.length, 100);
  assert.throws(() => normalize([expand("optic.left"), expand("optic.right"), expand("optic.third")], [largeDetail], observed), rejected);
});

test("the model can choose catalog detail but cannot author its resource, transform or provenance", () => {
  const normalized = normalize([{ ...expand(), assetID: "https://unapproved.test/a.usdz", provenance: { origin: "generated" }, transform: pose }]);
  const output = JSON.stringify(normalized.operations);
  assert.equal(output.includes("unapproved.test"), false);
  assert.equal(output.includes("generated"), false);
  assert.equal(output.includes(detail.assetID), true);
  const input = JSON.parse(formatUserInput({ requestId: "model", text: "Explain this", selectionNodeIds: ["optic.left"], scene: { nodes: [...nodes.values()] }, availableAssetDetails: [detail], signal: new AbortController().signal })) as JsonObject;
  assert.deepEqual(input.availableAssetDetails, [detail]);
  assert.equal(JSON.stringify(input.acceptedScene).includes("retaining-ring"), false, "unloaded parts must not appear in accepted scene");
});

test("the final instance retains exact source rest poses as reference context after expansion without authorizing another expansion", () => {
  const single = new Map<string, JsonObject>([["optic.left", structuredClone(nodes.get("optic.left")!)]]);
  const template = { ...detail, targetNodeIds: ["optic.left"] };
  const expanded = normalize([expand()], [template], single);
  const children = expanded.operations.filter((op) => op.op === "create.node").map((op) => asObject(op.node, "node"));
  const child = children[0]!;
  const restPose = structuredClone(detail.children[0]!.transform);
  child.transform = { ...restPose, translation: [0.4, 0.1, 0.2] };
  const reference = { ...template, targetNodeIds: [] };
  const snapshot = parseClientEnvelope({
    type: "phone.snapshot", sceneId: "scene.optic", revision: 5, intentEpoch: 8,
    document: {
      nodes: [{ ...single.get("optic.left")!, geometryId: null, materialId: null }, ...children],
      geometryDefinitions: expanded.operations.filter((op) => op.op === "put.geometry").map((op) => op.geometry)
    },
    availableAssetDetails: [reference]
  }) as PhoneSnapshot;
  const input = JSON.parse(formatUserInput({ requestId: "reassemble", text: "Put it back together", selectionNodeIds: ["optic.left"], scene: snapshot.document, availableAssetDetails: snapshot.availableAssetDetails, signal: new AbortController().signal })) as JsonObject;
  const projected = input.availableAssetDetails as unknown as AvailableAssetDetail[];
  assert.deepEqual(projected[0]!.targetNodeIds, []);
  assert.deepEqual(projected[0]!.children[0]!.transform, restPose);
  const acceptedNodes = asObject(asObject(input.acceptedScene, "accepted").scene, "scene").nodes as JsonObject[];
  assert.deepEqual(acceptedNodes.find((node) => node.nodeId === child.nodeId)!.transform, child.transform);
  assert.notDeepEqual(child.transform, restPose, "source reference must remain distinct from a displaced child's current pose");
  assert.deepEqual(acceptedNodes[0]!.transform, pose, "the selected parent's current placement remains authoritative");
  assert.throws(() => normalize([expand()], snapshot.availableAssetDetails, new Map(acceptedNodes.map((node) => [node.nodeId as string, node]))), rejected);
  assert.throws(() => normalize([{ ...expand(), nodeRef: child.nodeId as string }], snapshot.availableAssetDetails, new Map(acceptedNodes.map((node) => [node.nodeId as string, node]))), rejected);
});

test("session captures detail availability and waits for the native installation receipt before narration", async () => {
  const captured: ModelRequest[] = [];
  const model: ModelTransport = { async *stream(request): AsyncIterable<ModelEvent> {
    captured.push(request);
    yield { type: "function_call", name: "propose_scene", arguments: JSON.stringify(proposal([expand()])) };
    yield { type: "done" };
  } };
  const sent: JsonObject[] = [];
  const session = new AstraSession(model, { send: (message) => sent.push(message) });
  session.acceptHello({ type: "session.hello", protocolVersion: 1, sessionId: "session.optic", sceneId: "scene.optic", revision: 3, intentEpoch: 7, sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: [] });
  const advertised = structuredClone(detail);
  session.updateSnapshot({ type: "phone.snapshot", sceneId: "scene.optic", revision: 3, intentEpoch: 7, document: { nodes: [...nodes.values()] }, availableAssetDetails: [advertised] });
  advertised.children.length = 0;
  await session.request({ type: "user.request", requestId: "expand.1", text: "Explain these optical parts", selection: { nodeIds: ["optic.left"] } });
  assert.deepEqual(captured[0]!.availableAssetDetails, [detail]);
  const patch = sent.find((message) => message.type === "scene.patch")!;
  assert.ok(patch);
  assert.equal(patch.intentEpoch, 7);
  assert.equal(patch.baseRevision, 3);
  assert.equal(sent.some((message) => message.type === "session.explanation"), false);
  session.receiveReceipt({ type: "scene.receipt", protocolVersion: 1, sceneId: "scene.optic", requestId: patch.requestId as string, status: "installed", revision: 4, affectedNodeIds: ["optic.left"] });
  assert.equal(sent.filter((message) => message.type === "session.explanation").length, 1);

  session.updateSnapshot({ type: "phone.snapshot", sceneId: "scene.optic", revision: 4, intentEpoch: 8, document: { nodes: [...nodes.values()] } });
  await session.request({ type: "user.request", requestId: "expand.unavailable", text: "Explain again" });
  assert.deepEqual(captured[1]!.availableAssetDetails, []);
  assert.equal(sent.filter((message) => message.type === "scene.patch").length, 1, "old availability must not leak into a new snapshot");
  assert.equal(sent.some((message) => message.type === "session.error" && message.requestId === "expand.unavailable"), true);
  session.dispose();
});
