import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { JsonObject, ProtocolError, asObject } from "../src/json.js";
import { AuthoringProposal, geometryContentHash, normalizeProposal, payloadHash } from "../src/normalizer.js";

const transform = { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] };

function structural(nodeId: string, parentId: string | null = null): JsonObject {
  return { nodeId, parentId, geometryId: null, transform };
}

function flowRecipe(overrides: JsonObject = {}): JsonObject {
  return {
    kind: "flow", source: { nodeId: "source", localPoint: [0, 0, 0] },
    target: { nodeId: "target", localPoint: [0, 0.5, 0] }, routePoints: [[0.2, 0.3, 0.1]],
    direction: "forward", width: 0.01, label: "Air flow", animated: true, ...overrides
  };
}

function semanticFlow(alias = "annotation", overrides: JsonObject = {}): JsonObject {
  return { ...flowRecipe(), kind: "flow", alias, parentNodeRef: null, color: [0.1, 0.4, 1, 1], ...overrides };
}

function instance(alias: string, geometryAlias = "shared", parentAlias: string | null = null): JsonObject {
  return { kind: "node", alias, node: { parentAlias, geometryAlias, transform, semantic: { name: alias } } };
}

function proposal(operations: JsonObject[]): AuthoringProposal {
  return { mode: "patch", explanation: "Represent air movement.", scopeParentNodeId: null, operations };
}

function normalize(operations: JsonObject[], nodes: JsonObject[] = [structural("source"), structural("target")], geometries: JsonObject[] = [], flowEnabled = true, observedRelationships: JsonObject[] = []) {
  return normalizeProposal("flow-request", proposal(operations), new Set(nodes.map((node) => node.nodeId as string)),
    new Set(geometries.map((geometry) => geometry.geometryId as string)), new Map(nodes.map((node) => [node.nodeId as string, node])), [],
    { flowEnabled, observedGeometries: new Map(geometries.map((geometry) => [geometry.geometryId as string, geometry])), observedRelationships });
}

function definition(recipe = flowRecipe(), geometryId = "observed-flow"): JsonObject {
  return { geometryId, recipe, contentHash: geometryContentHash(recipe) };
}

const rejected = (error: unknown) => error instanceof ProtocolError;

test("semantic flow creates ordinary hashed geometry, opaque material, and stable generated node", () => {
  const result = normalize([semanticFlow()]);
  assert.deepEqual(result.operations.map((operation) => operation.op), ["put.geometry", "put.material", "create.node"]);
  const geometry = asObject(result.operations[0]!.geometry, "geometry"), material = asObject(result.operations[1]!.material, "material");
  const node = asObject(result.operations[2]!.node, "node");
  assert.deepEqual(geometry.recipe, flowRecipe());
  assert.equal(geometry.contentHash, geometryContentHash(flowRecipe()));
  assert.deepEqual(material.baseColorLinear, [0.1, 0.4, 1, 1]);
  assert.equal(node.geometryId, geometry.geometryId);
  assert.equal(node.materialId, material.materialId);
  assert.deepEqual(node.transform, transform);
  assert.deepEqual(node.provenance, { origin: "generated", factualSupport: "illustrative", sourceRefs: [] });
  assert.deepEqual(normalize([semanticFlow()]).operations, result.operations);
});

test("flow recipe updates retain annotation identity through set.geometry and lifecycle operations", () => {
  const nodes = [structural("source"), structural("target"), { ...structural("annotation"), geometryId: "observed-flow" }];
  const result = normalize([
    { kind: "geometry", alias: "reversed", recipe: flowRecipe({ direction: "reverse", animated: false }) },
    { kind: "setGeometry", nodeRef: "annotation", geometryAlias: "reversed" },
    { kind: "setVisibility", nodeRef: "annotation", visible: false }
  ], nodes, [definition()]);
  assert.equal(result.operations[1]!.nodeId, "annotation");
  assert.equal(result.operations[1]!.geometryId, asObject(result.operations[0]!.geometry, "geometry").geometryId);
  assert.deepEqual(result.operations[2], { op: "set.visibility", nodeId: "annotation", isVisible: false });
  assert.deepEqual(normalize([{ kind: "removeNode", nodeRef: "annotation" }], nodes, [definition()]).operations,
    [{ op: "remove.node", nodeId: "annotation" }]);
});

test("flow capability gates semantic operations, generic recipes, and observed geometry reuse", () => {
  for (const operations of [
    [semanticFlow()],
    [{ kind: "geometry", alias: "shared", recipe: flowRecipe() }],
    [instance("reuse", "observed-flow")],
    [{ kind: "setGeometry", nodeRef: "source", geometryAlias: "observed-flow" }]
  ]) {
    assert.throws(() => normalize(operations, undefined, [definition()], false), /flow\.v1 client capability/);
  }
  assert.throws(() => normalizeProposal("disabled", proposal([semanticFlow()]), new Set(["source", "target"])), /flow\.v1 client capability/);
});

test("flow shape enforces finite bounded points, width, UTF-8 labels, direction, and required fields", () => {
  const invalidRecipes: JsonObject[] = [
    { width: 0.0009 }, { width: 0.25001 }, { width: Infinity }, { label: "🌀".repeat(21) },
    { direction: "sideways" }, { animated: 1 }, { routePoints: Array(9).fill([0, 0, 0]) },
    { routePoints: [[10_001, 0, 0]] }, { routePoints: [[0, NaN, 0]] },
    { source: { nodeId: "source", localPoint: [0, 0] } },
    { source: { nodeId: "source", localPoint: [0, 0, 0], extra: true } }, { extra: "unsupported" }
  ];
  for (const overrides of invalidRecipes) {
    assert.throws(() => normalize([{ kind: "geometry", alias: "shared", recipe: flowRecipe(overrides) }]), rejected);
  }
  for (const field of ["source", "target", "routePoints", "direction", "width", "label", "animated"]) {
    const recipe = flowRecipe(); delete recipe[field];
    assert.throws(() => normalize([{ kind: "geometry", alias: "shared", recipe }]), rejected);
  }
  assert.doesNotThrow(() => normalize([semanticFlow("empty", { width: 0.001, label: "", routePoints: [] })]));
  assert.doesNotThrow(() => normalize([semanticFlow("unicode", { width: 0.25, label: "🌀".repeat(20) })]));
  assert.throws(() => normalize([semanticFlow("transparent", { color: [0, 0, 1, 0.5] })]), rejected);
  assert.throws(() => normalize([semanticFlow("extra", { simulationAccuracy: "verified" })]), /unknown semantic flow property/);
});

test("attachments may share a structural node only with distinct local points", () => {
  assert.doesNotThrow(() => normalize([semanticFlow("same-part", { target: { nodeId: "source", localPoint: [1, 0, 0] } })]));
  assert.throws(() => normalize([semanticFlow("coincident", { target: { nodeId: "source", localPoint: [-0, 0, 0] } })]), /distinct local points/);
});

test("only used flow definitions check missing endpoints", () => {
  const recipe = flowRecipe({ target: { nodeId: "missing", localPoint: [0, 0, 0] } });
  const geometryOperation = { kind: "geometry", alias: "shared", recipe };
  assert.doesNotThrow(() => normalize([geometryOperation]));
  assert.throws(() => normalize([geometryOperation, instance("used")]), /flow endpoint does not exist: missing/);
  assert.throws(() => normalize([semanticFlow("missing", { source: { nodeId: "not-a-node", localPoint: [0, 0, 0] } })]), /flow endpoint does not exist/);
});

test("every shared recipe instance checks structural endpoints and all flow subtrees", () => {
  const shared = definition();
  const nodes = [structural("target"), structural("source", "second"),
    { ...structural("first"), geometryId: "observed-flow" }, { ...structural("second"), geometryId: "observed-flow" }];
  assert.throws(() => normalize([{ kind: "setVisibility", nodeRef: "first", visible: true }], nodes, [shared]), /outside flow annotation subtrees/);
  const direct = [structural("target"), { ...structural("source"), geometryId: "observed-flow" }];
  assert.throws(() => normalize([semanticFlow()], direct, [shared]), /outside flow annotation subtrees/);
  // Changing a previously structural endpoint to a flow must invalidate existing bindings.
  assert.throws(() => normalize([{ kind: "setGeometry", nodeRef: "source", geometryAlias: "observed-flow" }],
    [structural("source"), structural("target"), { ...structural("first"), geometryId: "observed-flow" }], [shared]), /outside flow annotation subtrees/);
});

test("candidate hierarchy rejects cycles and orphan children before binding traversal", () => {
  assert.throws(() => normalize([semanticFlow()], [structural("source", "target"), structural("target", "source")]), /hierarchy cycle/);
  assert.throws(() => normalize([semanticFlow()], [structural("source", "missing"), structural("target")]), /missing parent/);
  assert.throws(() => normalize([
    { kind: "geometry", alias: "box", recipe: { kind: "box", size: [1, 1, 1] } }, instance("self", "box", "self")
  ]), /hierarchy cycle/);
});

test("bound parts and their annotations must be removed together in either operation order", () => {
  const nodes = [structural("source"), structural("target"), { ...structural("annotation"), geometryId: "observed-flow" }];
  const removePart = { kind: "removeNode", nodeRef: "source" }, removeFlow = { kind: "removeNode", nodeRef: "annotation" };
  assert.throws(() => normalize([removePart], nodes, [definition()]), /flow endpoint does not exist: source/);
  assert.doesNotThrow(() => normalize([removePart, removeFlow], nodes, [definition()]));
  assert.doesNotThrow(() => normalize([removeFlow, removePart], nodes, [definition()]));
  assert.throws(() => normalize([{ kind: "removeNode", nodeRef: "source" }], [structural("source"), structural("target", "source")]), /missing parent/);
  assert.doesNotThrow(() => normalize([{ kind: "removeNode", nodeRef: "source" }, { kind: "removeNode", nodeRef: "target" }], [structural("source"), structural("target", "source")]));
  assert.throws(() => normalize([removePart, { kind: "setVisibility", nodeRef: "source", visible: false }]), /removed node/);
});

test("flow budget counts hidden and shared instances and applies additions and removals exactly", () => {
  const nodes = [structural("source"), structural("target"), ...Array.from({ length: 32 }, (_, index) =>
    ({ ...structural(`flow-${index}`), geometryId: "observed-flow", isVisible: false }))];
  assert.doesNotThrow(() => normalize([{ kind: "setVisibility", nodeRef: "flow-0", visible: true }], nodes, [definition()]));
  assert.throws(() => normalize([instance("one-too-many", "observed-flow")], nodes, [definition()]), /32 flow instances/);
  assert.doesNotThrow(() => normalize([instance("replacement", "observed-flow"), { kind: "removeNode", nodeRef: "flow-0" }], nodes, [definition()]));
  assert.doesNotThrow(() => normalize([{ kind: "geometry", alias: "unused", recipe: flowRecipe() }], nodes, [definition()]));
  assert.doesNotThrow(() => normalize([{ kind: "setGeometry", nodeRef: "flow-0", geometryAlias: null }, instance("replacement", "observed-flow")], nodes, [definition()]));
});

test("flow expansion respects the existing 128 normalized operation budget", () => {
  // Unused ordinary definitions leave the scene budget unchanged, allowing the
  // expansion budget to be exercised independently of the 32-flow scene limit.
  const geometries = Array.from({ length: 126 }, (_, index) => ({ kind: "geometry", alias: `box-${index}`, recipe: { kind: "box", size: [1, 1, 1] } }));
  assert.throws(() => normalize([...geometries, semanticFlow()]), /exceeds 128 operations/);
});

test("removing an actual rack assembly explicitly removes only incident relationships", () => {
  const rack = JSON.parse(readFileSync(new URL("../../assets/server-rack/scene.json", import.meta.url), "utf8")) as JsonObject;
  const nodes = rack.nodes as JsonObject[], geometries = rack.geometryDefinitions as JsonObject[], relationships = rack.relationships as JsonObject[];
  const removedNodes = new Set(["server-1"]);
  let size = 0;
  while (size !== removedNodes.size) {
    size = removedNodes.size;
    for (const node of nodes) if (typeof node.parentId === "string" && removedNodes.has(node.parentId)) removedNodes.add(node.nodeId as string);
  }
  assert.equal(removedNodes.size, 94);
  const result = normalize([...removedNodes].map((nodeRef) => ({ kind: "removeNode", nodeRef })), nodes, geometries, true, relationships);
  const relationshipRemovals = result.operations.filter((operation) => operation.op === "remove.relationship");
  assert.deepEqual(relationshipRemovals, [
    { op: "remove.relationship", relationshipId: "server-1-network-uplink" },
    { op: "remove.relationship", relationshipId: "server-1-power-feed" }
  ]);
  assert.equal(result.operations.length, removedNodes.size + 2);
  assert.equal(result.operations.some((operation) => operation.relationshipId === "server-2-network-uplink"), false);
  assert.throws(() => normalize([{ kind: "removeNode", nodeRef: "server-1" }], nodes, geometries, true, relationships), /missing parent/);
});

test("incident relationship removals deduplicate across both endpoints and count against expansion budget", () => {
  const relation = { relationshipId: "source-target", sourceNodeId: "source", targetNodeId: "target" };
  const result = normalize([{ kind: "removeNode", nodeRef: "source" }, { kind: "removeNode", nodeRef: "target" }], undefined, [], true, [relation]);
  assert.deepEqual(result.operations, [
    { op: "remove.relationship", relationshipId: "source-target" }, { op: "remove.node", nodeId: "source" }, { op: "remove.node", nodeId: "target" }
  ]);
  // Independently generated by Swift CanonicalRequestHash.
  assert.equal(payloadHash({ type: "scene.patch", protocolVersion: 1, requestId: "remove-flow-rel", sceneId: "scene", intentEpoch: 0, baseRevision: 1,
    operations: result.operations.slice(0, 2) }), "22c4a00489d2b43b3f283cf763f795976a4eecf907d3367c264421a23649c81e");
  const manyRelations = Array.from({ length: 128 }, (_, index) => ({ ...relation, relationshipId: `relation-${index}` }));
  assert.throws(() => normalize([{ kind: "removeNode", nodeRef: "source" }], undefined, [], true, manyRelations), /exceeds 128 operations/);
});

test("all flow fields affect canonical geometry identity and signed zero is canonical", () => {
  const base = flowRecipe(), hash = geometryContentHash(base);
  const variants: JsonObject[] = [
    { source: { nodeId: "other", localPoint: [0, 0, 0] } }, { source: { nodeId: "source", localPoint: [1, 0, 0] } },
    { target: { nodeId: "other", localPoint: [0, 0.5, 0] } }, { target: { nodeId: "target", localPoint: [0, 1, 0] } },
    { routePoints: [[0.3, 0.2, 0.1]] }, { direction: "reverse" }, { width: 0.02 }, { label: "Heat flow" }, { animated: false }
  ];
  for (const changed of variants) assert.notEqual(geometryContentHash({ ...base, ...changed }), hash);
  assert.equal(geometryContentHash({ ...base, source: { nodeId: "source", localPoint: [-0, 0, -0] } }), hash);
});

test("flow hashes match the Swift-generated rack, energy, reversal, and patch fixtures", () => {
  const fixture = (name: string): JsonObject => JSON.parse(readFileSync(new URL(`../../framework/contract/fixtures/accepted/${name}.json`, import.meta.url), "utf8"));
  const energy = fixture("flow_energy_document"), rack = fixture("flow_rack_document");
  for (const document of [energy, rack]) {
    const geometries = document.geometryDefinitions as JsonObject[];
    for (const geometry of geometries) assert.equal(geometryContentHash(asObject(geometry.recipe, "recipe")), geometry.contentHash);
    const nodes = document.nodes as JsonObject[];
    assert.doesNotThrow(() => normalize([{ kind: "setVisibility", nodeRef: nodes[0]!.nodeId!, visible: true }], nodes, geometries));
  }
  const energyFlow = (energy.geometryDefinitions as JsonObject[]).find((geometry) => asObject(geometry.recipe, "recipe").kind === "flow")!;
  assert.equal(energyFlow.contentHash, "24fe9f7b3acc0d409dfed20451d089b6bf173a4e55f5d4a69355a35f8b41925d");
  assert.equal(geometryContentHash({ ...asObject(energyFlow.recipe, "energy recipe"), direction: "reverse", animated: false }),
    "bd7b2ce51be8936952abc501314fef2d93107527bee9b7f936c842172dda45b1");
  const patch = fixture("flow_patch");
  assert.equal(payloadHash(patch), "74d6425e2190b04f913ce68235c2e008c7631e699c4c5d603d2ab02e693a7207");
});
