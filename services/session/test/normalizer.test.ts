import assert from "node:assert/strict";
import test from "node:test";
import { JsonObject, ProtocolError, asObject } from "../src/json.js";
import { AuthoringProposal, geometryContentHash, normalizeProposal } from "../src/normalizer.js";

function proposal(operations: JsonObject[]): AuthoringProposal {
  return { mode: "patch", explanation: "Reuse an observed catalog part.", scopeParentNodeId: null, operations };
}

function nodeWithGeometry(geometryAlias: string): JsonObject {
  return {
    kind: "node", alias: "instance", node: {
      parentAlias: "node_parent", geometryAlias,
      transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] },
      semantic: { name: "Imported part" }, provenance: {}
    }
  };
}

function isRejection(message: string): (error: unknown) => boolean {
  return (error) => error instanceof ProtocolError && error.code === "proposal_rejected" && error.message === message;
}

test("translate preserves exact imported rotation and scale and composes sequential parent-space edits", () => {
  const transform = { translation: [0, 0.3720000088214874, 0.4000000059604645], rotation: [-0.7071067811865475, 0, 0, 0.7071067811865476], scale: [1, 2, 0.75] };
  const nodes = new Map<string, JsonObject>([["optical.mount", { nodeId: "optical.mount", transform }]]);
  const operations = normalizeProposal("move", proposal([
    { kind: "translate", nodeRef: "optical.mount", offset: [0, 0, 0.3] },
    { kind: "translate", nodeRef: "optical.mount", offset: [0.1, 0, -0.2] }
  ]), new Set(nodes.keys()), new Set(), nodes).operations;
  const first = asObject(operations[0]!.transform, "first transform");
  const second = asObject(operations[1]!.transform, "second transform");
  assert.deepEqual(first.rotation, transform.rotation);
  assert.deepEqual(second.rotation, transform.rotation);
  assert.deepEqual(second.scale, transform.scale);
  assert.deepEqual(first.translation, [0, transform.translation[1], transform.translation[2]! + 0.3]);
  assert.deepEqual(second.translation, [0.1, transform.translation[1], transform.translation[2]! + 0.3 - 0.2]);
  assert.deepEqual(nodes.get("optical.mount")!.transform, transform);
});

test("translate uses a preceding setTransform and never accepts a new alias or missing pose", () => {
  const nodes = new Map<string, JsonObject>([["node_parent", { nodeId: "node_parent", transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] } }]]);
  const changed = { translation: [1, 2, 3], rotation: [0, 0, 1, 0], scale: [2, 2, 2] };
  const output = normalizeProposal("mixed", proposal([
    { kind: "setTransform", nodeRef: "node_parent", transform: changed },
    { kind: "translate", nodeRef: "node_parent", offset: [0, 0.5, 0] }
  ]), new Set(nodes.keys()), new Set(), nodes).operations;
  assert.deepEqual(output[1]!.transform, { ...changed, translation: [1, 2.5, 3] });
  assert.throws(() => normalizeProposal("new", proposal([
    { ...nodeWithGeometry("geometry_imported") },
    { kind: "translate", nodeRef: "instance", offset: [0, 0, 1] }
  ]), new Set(nodes.keys()), new Set(["geometry_imported"]), nodes), isRejection("translate requires an observed node ID"));
  assert.throws(() => normalizeProposal("missing", proposal([{ kind: "translate", nodeRef: "node_parent", offset: [0, 0, 1] }]), new Set(nodes.keys())), isRejection("translate requires the observed node transform"));
});

test("translate rejects coordinate overflow and new nodes receive application provenance without model metadata", () => {
  const nodes = new Map<string, JsonObject>([["node_parent", { nodeId: "node_parent", transform: { translation: [9_999, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] } }]]);
  assert.throws(() => normalizeProposal("overflow", proposal([{ kind: "translate", nodeRef: "node_parent", offset: [2, 0, 0] }]), new Set(nodes.keys()), new Set(), nodes), isRejection("translated position exceeds coordinate bounds"));
  const op = nodeWithGeometry("geometry_imported");
  delete asObject(op.node, "node").provenance;
  const result = normalizeProposal("authorship", proposal([op]), new Set(nodes.keys()), new Set(["geometry_imported"]), nodes);
  assert.deepEqual(asObject(result.operations[0]!.node, "created node").provenance, { origin: "generated", factualSupport: "illustrative", sourceRefs: [] });
});

test("hashes imported asset references with the fixed canonical v1 vector", () => {
  const recipe = { kind: "importedAsset", assetID: "asset_fixture", partID: "part_fixture" };
  const hash = geometryContentHash(recipe);
  assert.equal(hash, "0f1b897908b19a74554743fc0b4a11abeabe032a92fb8171e3f3cd8a270746a9");
  assert.notEqual(geometryContentHash({ ...recipe, assetID: "asset_other" }), hash);
  assert.notEqual(geometryContentHash({ ...recipe, partID: "part_other" }), hash);
});

test("rejects model-authored imported asset recipes even when geometry was observed", () => {
  assert.throws(() => normalizeProposal("request_import", proposal([
    { kind: "geometry", alias: "invented", recipe: { kind: "importedAsset", assetID: "asset_fixture", partID: "part_fixture" } }
  ]), new Set(), new Set(["geometry_imported"])), isRejection("unsupported geometry recipe: importedAsset"));
});

test("reuses an observed geometry ID when creating a node and setting geometry", () => {
  const normalized = normalizeProposal("request_reuse", proposal([
    nodeWithGeometry("geometry_imported"),
    { kind: "setGeometry", nodeRef: "node_parent", geometryAlias: "geometry_imported" }
  ]), new Set(["node_parent"]), new Set(["geometry_imported"]));
  const node = asObject(normalized.operations[0]!.node, "created node");
  assert.equal(node.geometryId, "geometry_imported");
  assert.equal(node.parentId, "node_parent");
  assert.deepEqual(normalized.operations[1], { op: "set.geometry", nodeId: "node_parent", geometryId: "geometry_imported" });
});

test("rejects unknown geometry IDs for both creation and reassignment", () => {
  for (const operation of [nodeWithGeometry("geometry_unknown"), { kind: "setGeometry", nodeRef: "node_parent", geometryAlias: "geometry_unknown" }]) {
    assert.throws(() => normalizeProposal("request_unknown", proposal([operation]),
      new Set(["node_parent", "geometry_unknown"]), new Set(["geometry_imported"])),
    isRejection("unknown geometry alias: geometry_unknown"));
  }
});

test("defaults to rejecting geometry IDs that are not locally defined aliases", () => {
  assert.throws(() => normalizeProposal("request_default", proposal([
    { kind: "setGeometry", nodeRef: "node_parent", geometryAlias: "geometry_imported" }
  ]), new Set(["node_parent"])), isRejection("unknown geometry alias: geometry_imported"));
});

test("observed geometry IDs do not authorize node references or generation scope", () => {
  assert.throws(() => normalizeProposal("request_node", proposal([
    { kind: "setGeometry", nodeRef: "geometry_imported", geometryAlias: null }
  ]), new Set(), new Set(["geometry_imported"])), isRejection("unknown node alias: geometry_imported"));

  const generation: AuthoringProposal = {
    ...proposal([{ kind: "geometry", alias: "box", recipe: { kind: "box", size: [1, 1, 1] } }]),
    mode: "generation", scopeParentNodeId: "geometry_imported"
  };
  assert.throws(() => normalizeProposal("request_scope", generation, new Set(), new Set(["geometry_imported"])),
    isRejection("generation scope parent was not observed"));
  assert.equal(normalizeProposal("request_scope", generation, new Set(["geometry_imported"])).scopeParentNodeId, "geometry_imported");
});
