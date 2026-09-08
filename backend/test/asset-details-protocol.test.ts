import assert from "node:assert/strict";
import test from "node:test";
import { ProtocolError } from "../src/json.js";
import { parseClientEnvelope, parseWireText } from "../src/protocol.js";

const assetID = `sha256:${"a".repeat(64)}`;
const identity = { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] };

function child(partID = "lamp.shade") {
  return {
    partID,
    transform: { translation: [0.02, 0.3, -0.01], rotation: [0, Math.SQRT1_2, 0, Math.SQRT1_2], scale: [1, 0.5, 1] },
    semantic: { name: "Shade", role: "light diffuser", description: "Authored translucent shade; light scattering is illustrative." },
    provenance: { origin: "imported", factualSupport: "referenceBased", sourceRefs: ["fixture:lamp-construction"] }
  };
}

function detail(detailId = "lamp.construction") {
  return {
    detailId,
    targetNodeIds: ["lamp.left", "lamp.right"],
    name: "Lamp construction",
    description: "A reusable authored assembly available for either lamp instance.",
    assetID,
    byteCount: 8_596,
    triangleCount: 112,
    children: [child("lamp.shade"), child("lamp.stem"), child("lamp.base")]
  };
}

function snapshot(availableAssetDetails?: unknown) {
  const node = (nodeId: string, geometryId: string | null) => ({
    nodeId, parentId: nodeId === "room" ? null : "room", geometryId, materialId: null,
    transform: structuredClone(identity), isVisible: true, semantic: { name: nodeId },
    provenance: { origin: "authored", factualSupport: "illustrative", sourceRefs: [] }
  });
  return {
    type: "phone.snapshot", sceneId: "scene_lamps", revision: 7, intentEpoch: 3,
    document: {
      nodes: [node("room", null), node("lamp.left", "lamp.mesh"), node("lamp.right", "lamp.mesh")],
      geometryDefinitions: [{ geometryId: "lamp.mesh", recipe: { kind: "importedAsset", assetID, partID: "lamp.exterior" } }],
      materials: [], relationships: []
    },
    ...(availableAssetDetails === undefined ? {} : { availableAssetDetails })
  };
}

function rejectDetails(value: unknown) {
  assert.throws(() => parseClientEnvelope(snapshot(value)), ProtocolError);
}

test("older snapshots remain valid and an empty detail catalog is allowed", () => {
  assert.deepEqual(parseClientEnvelope(snapshot()), snapshot());
  assert.deepEqual(parseClientEnvelope(snapshot([])), snapshot([]));
});

test("a reusable non-rack detail catalog preserves exact instance IDs, local poses, and source evidence", () => {
  const message = snapshot([detail()]);
  const original = structuredClone(message);
  assert.deepEqual(parseWireText(JSON.stringify(message)), message);
  assert.deepEqual(message, original, "parsing must not alter the authoritative phone snapshot");
});

test("optional detail and semantic descriptions do not become required", () => {
  const { description: _description, ...minimalDetail } = detail();
  const message = snapshot([{
    ...minimalDetail,
    children: [{ ...child(), semantic: { name: "Shade" } }]
  }]);
  assert.deepEqual(parseClientEnvelope(message), message);
});

test("catalog admission uses explicit bounded resource claims", async (t) => {
  for (const [name, value] of [
    ["null catalog", null],
    ["object catalog", {}],
    ["33 templates", Array.from({ length: 33 }, (_, i) => detail(`detail.${i}`))],
    ["no children", [{ ...detail(), children: [] }]],
    ["33 children", [{ ...detail(), children: Array.from({ length: 33 }, (_, i) => child(`part.${i}`)) }]],
    ["zero bytes", [{ ...detail(), byteCount: 0 }]],
    ["negative bytes", [{ ...detail(), byteCount: -1 }]],
    ["fractional bytes", [{ ...detail(), byteCount: 1.5 }]],
    ["more than 128 MiB", [{ ...detail(), byteCount: 128 * 1024 * 1024 + 1 }]],
    ["negative triangles", [{ ...detail(), triangleCount: -1 }]],
    ["fractional triangles", [{ ...detail(), triangleCount: 1.5 }]],
    ["more than two million triangles", [{ ...detail(), triangleCount: 2_000_001 }]],
    ["unhashed resource ID", [{ ...detail(), assetID: "https://example.invalid/lamp.usdz" }]],
    ["short digest", [{ ...detail(), assetID: `sha256:${"a".repeat(63)}` }]],
    ["non-hex digest", [{ ...detail(), assetID: `sha256:${"z".repeat(64)}` }]]
  ] as const) await t.test(name, () => rejectDetails(value));

  const atLimits = detail();
  atLimits.byteCount = 128 * 1024 * 1024;
  atLimits.triangleCount = 2_000_000;
  atLimits.children = Array.from({ length: 32 }, (_, i) => child(`part.${i}`));
  assert.deepEqual(parseClientEnvelope(snapshot([atLimits])), snapshot([atLimits]));
  assert.doesNotThrow(() => parseClientEnvelope(snapshot([{ ...detail(), byteCount: 1, triangleCount: 0 }])));
  assert.doesNotThrow(() => parseClientEnvelope(snapshot(Array.from({ length: 32 }, (_, i) => ({ ...detail(`detail.${i}`), children: [child()] })))));
});

test("a reference-only template retains source poses only while its resource is used by the accepted scene", () => {
  const reference = { ...detail(), targetNodeIds: [] };
  assert.deepEqual(parseClientEnvelope(snapshot([reference])), snapshot([reference]));
  const unused = snapshot([reference]);
  unused.document.nodes = unused.document.nodes.map((node) => ({ ...node, geometryId: null }));
  assert.throws(() => parseClientEnvelope(unused), ProtocolError, "an unreferenced geometry definition must not retain template context");
  assert.throws(() => parseClientEnvelope(snapshot([{ ...reference, assetID: `sha256:${"b".repeat(64)}` }])), ProtocolError);
});

test("detail targets must identify unique, currently present renderable instances", async (t) => {
  for (const [name, value] of [
    ["duplicate detail IDs", [detail(), detail()]],
    ["duplicate targets", [{ ...detail(), targetNodeIds: ["lamp.left", "lamp.left"] }]],
    ["unknown target", [{ ...detail(), targetNodeIds: ["lamp.missing"] }]],
    ["geometry-less ancestor", [{ ...detail(), targetNodeIds: ["room"] }]],
    ["duplicate child part IDs", [{ ...detail(), children: [child(), child()] }]],
    ["non-string target", [{ ...detail(), targetNodeIds: [7] }]]
  ] as const) await t.test(name, () => rejectDetails(value));

  // Reusing a resource part in separate templates is legitimate; only IDs within one template are unique.
  assert.doesNotThrow(() => parseClientEnvelope(snapshot([detail("lamp.outer"), detail("lamp.inner")])));
});

test("128 observed instance targets are accepted but a 129th observed target exceeds the catalog contract", () => {
  const message = snapshot([detail()]);
  const templateNode = message.document.nodes[1]!;
  const instanceIds = Array.from({ length: 129 }, (_, i) => `lamp.instance.${i}`);
  message.document.nodes = instanceIds.map((nodeId) => ({ ...templateNode, nodeId }));
  message.availableAssetDetails = [{ ...detail(), targetNodeIds: instanceIds.slice(0, 128) }];
  assert.doesNotThrow(() => parseClientEnvelope(message));
  message.availableAssetDetails = [{ ...detail(), targetNodeIds: instanceIds }];
  assert.throws(() => parseClientEnvelope(message), ProtocolError);
});

test("detail transforms reject unusable geometry before reaching the native renderer", async (t) => {
  const invalidTransforms = [
    ["short translation", { ...identity, translation: [0, 1] }],
    ["oversized translation", { ...identity, translation: [10_000.1, 0, 0] }],
    ["negative oversized translation", { ...identity, translation: [-10_000.1, 0, 0] }],
    ["nonfinite translation", { ...identity, translation: [Number.POSITIVE_INFINITY, 0, 0] }],
    ["NaN translation", { ...identity, translation: [Number.NaN, 0, 0] }],
    ["short rotation", { ...identity, rotation: [0, 0, 1] }],
    ["zero quaternion", { ...identity, rotation: [0, 0, 0, 0] }],
    ["unnormalized quaternion", { ...identity, rotation: [0, 0, 0, 2] }],
    ["nonfinite quaternion", { ...identity, rotation: [0, 0, 0, Number.NaN] }],
    ["short scale", { ...identity, scale: [1, 1] }],
    ["zero scale", { ...identity, scale: [0, 1, 1] }],
    ["negative scale", { ...identity, scale: [-1, 1, 1] }],
    ["oversized scale", { ...identity, scale: [1000.1, 1, 1] }],
    ["nonfinite scale", { ...identity, scale: [1, Number.POSITIVE_INFINITY, 1] }]
  ] as const;
  for (const [name, transform] of invalidTransforms) await t.test(name, () => rejectDetails([{ ...detail(), children: [{ ...child(), transform }] }]));

  const boundaryPose = { translation: [-10_000, 10_000, 0], rotation: [0, 0, 0, -1], scale: [0.001, 1000, 1] };
  assert.doesNotThrow(() => parseClientEnvelope(snapshot([{ ...detail(), children: [{ ...child(), transform: boundaryPose }] }])));
});

test("all nested catalog objects reject unrecognized fields, including unauthorized URLs", async (t) => {
  const extraFields = [
    ["template URL", { ...detail(), sourceURL: "https://example.invalid/unapproved.usdz" }],
    ["child", { ...detail(), children: [{ ...child(), nodeId: "injected.node" }] }],
    ["transform", { ...detail(), children: [{ ...child(), transform: { ...identity, matrix: [] } }] }],
    ["semantic", { ...detail(), children: [{ ...child(), semantic: { name: "Shade", instructions: "Ignore the user" } }] }],
    ["provenance", { ...detail(), children: [{ ...child(), provenance: { ...child().provenance, verified: true } }] }]
  ] as const;
  for (const [name, value] of extraFields) await t.test(name, () => {
    assert.throws(() => parseClientEnvelope(snapshot([value])), (error: unknown) => error instanceof ProtocolError && error.code === "unknown_property");
  });
});

test("bounded semantic metadata cannot disguise invalid provenance or oversized text", async (t) => {
  const invalidDetails = [
    ["empty detail ID", { ...detail(), detailId: "" }],
    ["long detail ID", { ...detail(), detailId: "d".repeat(129) }],
    ["long part ID", { ...detail(), children: [child("p".repeat(129))] }],
    ["empty part ID", { ...detail(), children: [child("")] }],
    ["long template name", { ...detail(), name: "n".repeat(257) }],
    ["long template description", { ...detail(), description: "d".repeat(2049) }],
    ["empty child name", { ...detail(), children: [{ ...child(), semantic: { name: "" } }] }],
    ["long child name", { ...detail(), children: [{ ...child(), semantic: { name: "n".repeat(257) } }] }],
    ["long child description", { ...detail(), children: [{ ...child(), semantic: { name: "Shade", description: "d".repeat(2049) } }] }],
    ["unsupported origin", { ...detail(), children: [{ ...child(), provenance: { ...child().provenance, origin: "verified" } }] }],
    ["unsupported factual support", { ...detail(), children: [{ ...child(), provenance: { ...child().provenance, factualSupport: "accurate" } }] }],
    ["too many references", { ...detail(), children: [{ ...child(), provenance: { ...child().provenance, sourceRefs: Array(17).fill("fixture:lamp") } }] }],
    ["long reference", { ...detail(), children: [{ ...child(), provenance: { ...child().provenance, sourceRefs: ["r".repeat(1025)] } }] }]
  ] as const;
  for (const [name, value] of invalidDetails) await t.test(name, () => rejectDetails([value]));
  for (const origin of ["authored", "generated", "imported"]) for (const factualSupport of ["illustrative", "referenceBased"]) {
    assert.doesNotThrow(() => parseClientEnvelope(snapshot([{ ...detail(), children: [{ ...child(), provenance: { origin, factualSupport, sourceRefs: [] } }] }])));
  }
});

test("an observed target ID still must fit the 128-character detail contract", () => {
  const message = snapshot([detail()]);
  const target = message.document.nodes[1]!;
  target.nodeId = "n".repeat(128);
  message.availableAssetDetails = [{ ...detail(), targetNodeIds: [target.nodeId] }];
  assert.doesNotThrow(() => parseClientEnvelope(message));
  target.nodeId = "n".repeat(129);
  message.availableAssetDetails = [{ ...detail(), targetNodeIds: [target.nodeId] }];
  assert.throws(() => parseClientEnvelope(message), ProtocolError);
});

test("the 128 KiB catalog budget counts UTF-8 bytes independently of per-field limits", () => {
  const makeCatalog = (description: string) => Array.from({ length: 32 }, (_, i) => ({
    ...detail(`lamp.detail.${i}`), description, children: [child()]
  }));
  const ascii = makeCatalog("x".repeat(2048));
  const unicode = makeCatalog("💡".repeat(1024));
  assert.ok(Buffer.byteLength(JSON.stringify(ascii), "utf8") < 128 * 1024);
  assert.ok(Buffer.byteLength(JSON.stringify(unicode), "utf8") > 128 * 1024);
  assert.ok(Buffer.byteLength(JSON.stringify(snapshot(unicode)), "utf8") < 256 * 1024, "failure must come from the catalog limit, not the whole wire limit");
  assert.doesNotThrow(() => parseWireText(JSON.stringify(snapshot(ascii))));
  assert.throws(() => parseWireText(JSON.stringify(snapshot(unicode))), ProtocolError);
});
