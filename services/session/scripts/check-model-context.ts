import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { JsonObject, asObject, isObject } from "../src/json.js";
import { sceneContext } from "../src/astra/scene-context.js";

const root = new URL("../../../", import.meta.url);
const bytes = (value: unknown): number => Buffer.byteLength(JSON.stringify(value), "utf8");
const reduction = (before: number, after: number): number => Math.round((1 - after / before) * 10_000) / 100;
const samples = ["contracts/fixtures/accepted/imported_rack_document.json", "examples/server-rack/scene.json"].map((path) => {
  const file = readFileSync(new URL(path, root));
  const document = JSON.parse(file.toString("utf8")) as JsonObject;
  const context = sceneContext(document);
  const nodes = Array.isArray(document.nodes) ? document.nodes.filter(isObject) : [];
  const geometries = Array.isArray(document.geometryDefinitions) ? document.geometryDefinitions.filter(isObject) : [];
  const before = bytes(document), after = bytes(context);
  return { fixture: path, fixtureSHA256: createHash("sha256").update(file).digest("hex"), nodes: nodes.length, geometries: geometries.length, originalDocumentBytes: before, modelContextBytes: after, inputByteReductionPercent: reduction(before, after) };
});

const imported = JSON.parse(readFileSync(new URL("contracts/fixtures/accepted/imported_rack_document.json", root), "utf8")) as JsonObject;
const assemblyNodes = (imported.nodes as JsonObject[]).filter((node) => asObject(node.semantic, "semantic").role === "server");
const offset = [0, 0, 0.3];
const absoluteOperations = assemblyNodes.map((node) => {
  const transform = asObject(node.transform, "transform");
  const position = transform.translation as number[];
  return { kind: "setTransform", nodeRef: node.nodeId, transform: { ...transform, translation: position.map((value, index) => value + offset[index]!) } };
});
const relativeOperations = assemblyNodes.map((node) => ({ kind: "translate", nodeRef: node.nodeId, offset }));
const before = bytes(absoluteOperations), after = bytes(relativeOperations);
const sourceFiles = ["services/session/src/astra/scene-context.ts", "services/session/src/astra/authoring-tool.ts", "services/session/src/astra/instructions.ts", "services/session/src/astra/conversation-context.ts", "services/session/src/astra/client.ts", "services/session/src/normalizer.ts", "services/session/src/session.ts", "services/session/src/diagnostics.ts"];
const evidence = {
  schema: "astra-model-context-optimization/v1",
  measuredAt: new Date().toISOString(),
  reproduce: "cd services/session && npm run check:context",
  scope: "Local deterministic JSON byte measurements; no provider token counts, cache-hit, latency or physical-rendering claim.",
  semanticChecks: "scene-context.test.ts independently restores shared references and deep-compares every authoring field, excluding application-owned geometry contentHash; all nodes, IDs, parent links, exact TRS, visibility, semantics, provenance, recipes, materials and relationships remain.",
  contextSamples: samples,
  outputSample: { task: "Translate all 18 imported server assemblies by 0.3 source metres in parent +Z, retaining child structure", operations: assemblyNodes.length, priorSetTransformBytes: before, translateBytes: after, outputByteReductionPercent: reduction(before, after), nativeWireOperationUnchanged: "set.transform" },
  history: { maximumTurns: 6, maximumUTF8Bytes: 12_288, records: "Whole terminal answered/installed/explicit failed outcomes only; current snapshot remains authoritative." },
  sourceSHA256: Object.fromEntries(sourceFiles.map((path) => [path, createHash("sha256").update(readFileSync(new URL(path, root))).digest("hex")]))
};
const destination = new URL("evidence/model-context-optimization.json", root);
writeFileSync(destination, `${JSON.stringify(evidence, null, 2)}\n`);
console.log(JSON.stringify({ contextSamples: samples, outputSample: evidence.outputSample, evidence: fileURLToPath(destination) }, null, 2));
