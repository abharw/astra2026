import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { JsonObject, asObject, isObject } from "../src/json.js";
import { sceneContext } from "../src/astra/scene-context.js";

function fixture(path: string): JsonObject {
  return JSON.parse(readFileSync(new URL(`../../../${path}`, import.meta.url), "utf8"));
}

// Independently expand context references to verify all authoring facts survive.
function expand(context: JsonObject): JsonObject {
  const scene = structuredClone(asObject(context.scene, "scene"));
  const shared = asObject(context.shared, "shared");
  const descriptions = asObject(shared.descriptions, "descriptions");
  const provenances = asObject(shared.provenances, "provenances");
  const assets = asObject(shared.assets, "assets");
  for (const node of Array.isArray(scene.nodes) ? scene.nodes.filter(isObject) : []) {
    if (typeof node.provenanceRef === "string") { node.provenance = provenances[node.provenanceRef]!; delete node.provenanceRef; }
    if (isObject(node.semantic) && typeof node.semantic.descriptionRef === "string") {
      node.semantic.description = descriptions[node.semantic.descriptionRef]!;
      delete node.semantic.descriptionRef;
    }
  }
  for (const geometry of Array.isArray(scene.geometryDefinitions) ? scene.geometryDefinitions.filter(isObject) : []) {
    if (isObject(geometry.recipe) && typeof geometry.recipe.assetRef === "string") {
      geometry.recipe.assetID = assets[geometry.recipe.assetRef]!;
      delete geometry.recipe.assetRef;
    }
  }
  return scene;
}

function authoringFacts(document: JsonObject): JsonObject {
  const expected = structuredClone(document);
  if (Array.isArray(expected.geometryDefinitions)) for (const geometry of expected.geometryDefinitions.filter(isObject)) delete geometry.contentHash;
  return expected;
}

for (const [name, path] of [
  ["actual native imported rack", "contracts/fixtures/accepted/imported_rack_document.json"],
  ["179-node procedural rack", "examples/server-rack/scene.json"]
]) test(`compact context exactly retains every authoring fact in ${name}`, () => {
  const document = fixture(path!);
  const original = structuredClone(document);
  const context = sceneContext(document);
  assert.deepEqual(expand(context), authoringFacts(document));
  assert.deepEqual(document, original, "model projection must never mutate accepted state");
  assert.ok(JSON.stringify(context).length < JSON.stringify(document).length);
  const originalIds = (document.nodes as JsonObject[]).map((node) => node.nodeId);
  assert.deepEqual((asObject(context.scene, "scene").nodes as JsonObject[]).map((node) => node.nodeId), originalIds);
});

test("the same context preserves a non-rack optical assembly without inferring new hierarchy", () => {
  const document: JsonObject = {
    schemaVersion: 1, geometrySemanticsVersion: 1, documentId: "optics",
    geometryDefinitions: [{ geometryId: "lens.mesh", contentHash: "application-owned", recipe: { kind: "sphere", radius: 0.018, segments: 24 } }],
    materials: [{ materialId: "lens.material", baseColorLinear: [0.1, 0.5, 0.8, 1], metallic: 0, roughness: 0.1 }],
    nodes: [
      { nodeId: "optics", transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [2, 2, 2] }, semantic: { name: "Optical bench", role: "assembly" }, provenance: { origin: "authored", factualSupport: "referenceBased", sourceRefs: ["manual:optics"] } },
      ...["objective", "eyepiece"].map((id, index) => ({ nodeId: `optics.${id}`, parentId: "optics", geometryId: "lens.mesh", materialId: "lens.material", transform: { translation: [0, 0, index * 0.2], rotation: [0, 0, 0, 1], scale: [1, 1, 0.25] }, isVisible: index === 0, semantic: { name: id, role: "lens", description: "Illustrative optical surface; ray paths are not simulated." }, provenance: { origin: "generated", factualSupport: "illustrative", sourceRefs: [] } }))
    ],
    relationships: [{ relationshipId: "path", kind: "opticalPath", sourceNodeId: "optics.objective", targetNodeId: "optics.eyepiece", description: "Schematic light path" }]
  };
  assert.deepEqual(expand(sceneContext(document)), authoringFacts(document));
});
