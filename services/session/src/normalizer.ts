import { createHash } from "node:crypto";
import { JsonObject, ProtocolError, asObject, isNumber, isString, requireArray, requireString } from "./json.js";

export interface AuthoringProposal {
  mode: "generation" | "patch" | "explanation";
  explanation: string;
  scopeParentNodeId: string | null;
  operations: JsonObject[];
}

export interface NormalizedProposal {
  mode: "generation" | "patch" | "explanation";
  explanation: string;
  scopeParentNodeId?: string;
  operations: JsonObject[];
}

/**
 * Resolves model-local aliases to deterministic IDs. The emitted operation tags
 * deliberately match the portable v1 contract; native code remains authority
 * for semantic validity and installation.
 */
export function normalizeProposal(requestId: string, proposal: AuthoringProposal, observedNodeIds: Set<string>): NormalizedProposal {
  const aliases = new Map<string, string>();
  const operationCount = proposal.operations.length;
  if (operationCount > 128 || (proposal.mode === "explanation" && operationCount !== 0) || (proposal.mode !== "explanation" && operationCount === 0)) {
    throw new ProtocolError("explanations require zero operations; mutations require 1-128 operations", "proposal_rejected");
  }
  if (proposal.mode === "explanation" && proposal.scopeParentNodeId !== null) throw new ProtocolError("explanations cannot reserve a generation scope", "proposal_rejected");
  const resolve = (value: unknown, kind: "node" | "geometry" | "material", allowObserved = false): string => {
    if (!isString(value) || value.length === 0 || value.length > 128) throw new ProtocolError(`invalid ${kind} reference`, "proposal_rejected");
    if (allowObserved && observedNodeIds.has(value)) return value;
    const existing = aliases.get(`${kind}:${value}`);
    if (existing) return existing;
    throw new ProtocolError(`unknown ${kind} alias: ${value}`, "proposal_rejected");
  };
  const define = (alias: unknown, kind: "node" | "geometry" | "material"): string => {
    if (!isString(alias) || alias.length === 0 || alias.length > 128) throw new ProtocolError(`invalid ${kind} alias`, "proposal_rejected");
    const key = `${kind}:${alias}`;
    if (aliases.has(key)) throw new ProtocolError(`duplicate ${kind} alias: ${alias}`, "proposal_rejected");
    const id = stableId(kind, requestId, alias);
    aliases.set(key, id);
    return id;
  };

  const operations: JsonObject[] = [];
  for (const source of proposal.operations) {
    const kind = requireString(source, "kind", 64);
    switch (kind) {
      case "geometry": {
        const geometryId = define(source.alias, "geometry");
        const recipe = normalizeRecipe(asObject(source.recipe, "geometry.recipe"));
        operations.push({ op: "put.geometry", geometry: { geometryId, contentHash: geometryContentHash(recipe), recipe } });
        break;
      }
      case "material": {
        const materialId = define(source.alias, "material");
        const material = asObject(source.material, "material.material");
        operations.push({ op: "put.material", material: {
          materialId, baseColorLinear: numericArray(material, "baseColorLinear", 4), metallic: numberField(material, "metallic"), roughness: numberField(material, "roughness")
        } });
        break;
      }
      case "node": {
        const nodeId = define(source.alias, "node");
        const node = asObject(source.node, "node.node");
        const parentAlias = node.parentAlias;
        const parentId = parentAlias === null || parentAlias === undefined ? null : resolve(parentAlias, "node", true);
        const geometryAlias = node.geometryAlias;
        const materialAlias = node.materialAlias;
        const semantic = asObject(node.semantic, "node.semantic");
        asObject(node.provenance, "node.provenance");
        const clean: JsonObject = {
          nodeId, parentId, geometryId: geometryAlias === null || geometryAlias === undefined ? null : resolve(geometryAlias, "geometry"),
          materialId: materialAlias === null || materialAlias === undefined ? null : resolve(materialAlias, "material"),
          transform: canonicalTransform(asObject(node.transform, "node.transform")),
          isVisible: node.isVisible === undefined ? true : booleanField(node, "isVisible"),
          semantic: { name: requireString(semantic, "name", 512), role: optionalString(semantic, "role"), description: optionalString(semantic, "description") },
          provenance: { origin: "generated", factualSupport: "illustrative", sourceRefs: [] }
        };
        operations.push({ op: "create.node", node: clean });
        break;
      }
      case "setTransform": {
        operations.push({ op: "set.transform", nodeId: resolve(source.nodeRef, "node", true), transform: canonicalTransform(asObject(source.transform, "setTransform.transform")) });
        break;
      }
      case "setGeometry": {
        operations.push({ op: "set.geometry", nodeId: resolve(source.nodeRef, "node", true), geometryId: source.geometryAlias === null ? null : resolve(source.geometryAlias, "geometry") });
        break;
      }
      case "setMaterial": {
        operations.push({ op: "set.material", nodeId: resolve(source.nodeRef, "node", true), materialId: source.materialAlias === null ? null : resolve(source.materialAlias, "material") });
        break;
      }
      case "setVisibility": {
        if (typeof source.visible !== "boolean") throw new ProtocolError("setVisibility.visible must be boolean", "proposal_rejected");
        operations.push({ op: "set.visibility", nodeId: resolve(source.nodeRef, "node", true), isVisible: source.visible });
        break;
      }
      default: throw new ProtocolError(`unsupported authoring operation: ${kind}`, "proposal_rejected");
    }
  }
  if (proposal.mode === "generation" && proposal.scopeParentNodeId !== null && !observedNodeIds.has(proposal.scopeParentNodeId)) {
    throw new ProtocolError("generation scope parent was not observed", "proposal_rejected");
  }
  return { mode: proposal.mode, explanation: proposal.explanation, scopeParentNodeId: proposal.scopeParentNodeId ?? undefined, operations };
}

export function parseAuthoringProposal(value: unknown): AuthoringProposal {
  const object = asObject(value, "model proposal");
  const mode = requireString(object, "mode", 32);
  if (mode !== "generation" && mode !== "patch" && mode !== "explanation") throw new ProtocolError("proposal mode must be generation, patch, or explanation", "proposal_rejected");
  const explanation = requireString(object, "explanation", 1_000);
  const scope = object.scopeParentNodeId;
  if (scope !== null && !isString(scope)) throw new ProtocolError("scopeParentNodeId must be string or null", "proposal_rejected");
  const operations = requireArray(object, "operations", 128).map((item) => asObject(item, "proposal operation"));
  return { mode, explanation, scopeParentNodeId: scope, operations };
}

export function payloadHash(envelopeWithoutHash: JsonObject): string {
  const writer = new CanonicalWriter();
  writer.header();
  const type = requireString(envelopeWithoutHash, "type");
  writer.string(type); writer.integer(numberField(envelopeWithoutHash, "protocolVersion")); writer.string(requireString(envelopeWithoutHash, "requestId")); writer.string(requireString(envelopeWithoutHash, "sceneId"));
  if (type === "generation.batch") {
    writer.string(requireString(envelopeWithoutHash, "generationId")); writer.unsigned(numberField(envelopeWithoutHash, "intentEpoch")); writer.unsigned(numberField(envelopeWithoutHash, "sequence")); writer.operations(operationArray(envelopeWithoutHash));
  } else if (type === "scene.patch") {
    writer.unsigned(numberField(envelopeWithoutHash, "intentEpoch")); writer.unsigned(numberField(envelopeWithoutHash, "baseRevision")); writer.operations(operationArray(envelopeWithoutHash));
  } else throw new ProtocolError("payload hashes are only defined for batch and patch", "proposal_rejected");
  return createHash("sha256").update(Buffer.concat(writer.data)).digest("hex");
}

export function geometryContentHash(recipe: JsonObject): string {
  const writer = new CanonicalWriter(); writer.header("astra-geometry-v1"); writer.integer(1); writer.recipe(recipe);
  return createHash("sha256").update(Buffer.concat(writer.data)).digest("hex");
}

class CanonicalWriter {
  readonly data: Buffer[] = [];
  header(value = "astra-request-v1"): void { this.data.push(Buffer.from(value, "utf8"), Buffer.from([0])); }
  byte(value: number): void { this.data.push(Buffer.from([value])); }
  unsigned(value: number): void { if (!Number.isSafeInteger(value) || value < 0) throw new ProtocolError("invalid unsigned integer", "proposal_rejected"); const out = Buffer.alloc(8); out.writeBigUInt64BE(BigInt(value)); this.data.push(out); }
  integer(value: number): void { if (!Number.isSafeInteger(value)) throw new ProtocolError("invalid integer", "proposal_rejected"); const out = Buffer.alloc(8); out.writeBigInt64BE(BigInt(value)); this.data.push(out); }
  count(value: number): void { if (!Number.isSafeInteger(value) || value < 0 || value > 0xffff_ffff) throw new ProtocolError("invalid collection count", "proposal_rejected"); const out = Buffer.alloc(4); out.writeUInt32BE(value); this.data.push(out); }
  string(value: string): void { const bytes = Buffer.from(value, "utf8"); this.count(bytes.length); this.data.push(bytes); }
  optionalString(value: string | null): void { if (value === null) this.byte(0); else { this.byte(1); this.string(value); } }
  double(value: number): void { if (!Number.isFinite(value)) throw new ProtocolError("non-finite numeric value", "proposal_rejected"); const out = Buffer.alloc(8); out.writeDoubleBE(Object.is(value, -0) ? 0 : value); this.data.push(out); }
  vec3(value: unknown): void { const values = vector(value, 3); values.forEach((number) => this.double(number)); }
  quaternion(value: unknown): void { const values = vector(value, 4); values.forEach((number) => this.double(number)); }
  transform(value: JsonObject): void { this.vec3(value.translation); this.quaternion(value.rotation); this.vec3(value.scale); }
  recipe(value: JsonObject): void {
    const kind = requireString(value, "kind"); this.string(kind);
    switch (kind) {
      case "box": this.vec3(value.size); return;
      case "sphere": this.double(numberField(value, "radius")); this.integer(integerFieldOr(value, "segments", 24)); return;
      case "cylinder": this.double(numberField(value, "radius")); this.double(numberField(value, "height")); this.integer(integerFieldOr(value, "radialSegments", 24)); return;
      case "cone": this.double(numberField(value, "bottomRadius")); this.double(numberField(value, "topRadius")); this.double(numberField(value, "height")); this.integer(integerFieldOr(value, "radialSegments", 24)); return;
      case "tube": { const points = requireArray(value, "points", 256); this.count(points.length); points.forEach((point) => this.vec3(point)); this.double(numberField(value, "radius")); this.integer(integerFieldOr(value, "radialSegments", 12)); return; }
      case "arrow": this.vec3(value.start); this.vec3(value.end); this.double(numberField(value, "shaftRadius")); this.double(numberField(value, "headRadius")); this.double(numberField(value, "headLength")); this.integer(integerFieldOr(value, "radialSegments", 16)); return;
      default: throw new ProtocolError(`unsupported geometry recipe: ${kind}`, "proposal_rejected");
    }
  }
  geometry(value: JsonObject): void { this.string(requireString(value, "geometryId")); this.string(requireString(value, "contentHash")); this.recipe(asObject(value.recipe, "geometry recipe")); }
  material(value: JsonObject): void { this.string(requireString(value, "materialId")); const color = numericArray(value, "baseColorLinear", 4); this.count(color.length); color.forEach((channel) => this.double(channel)); this.double(numberField(value, "metallic")); this.double(numberField(value, "roughness")); }
  semantic(value: JsonObject): void { this.string(requireString(value, "name")); this.optionalString(optionalString(value, "role")); this.optionalString(optionalString(value, "description")); }
  provenance(value: JsonObject): void { this.string(enumField(value, "origin", ["authored", "generated", "imported"])); this.string(enumField(value, "factualSupport", ["illustrative", "referenceBased"])); const sources = stringArray(value, "sourceRefs", 64); this.count(sources.length); sources.forEach((source) => this.string(source)); }
  node(value: JsonObject): void { this.string(requireString(value, "nodeId")); this.optionalString(optionalString(value, "parentId")); this.optionalString(optionalString(value, "geometryId")); this.optionalString(optionalString(value, "materialId")); this.transform(asObject(value.transform, "node transform")); this.byte(booleanField(value, "isVisible") ? 1 : 0); this.semantic(asObject(value.semantic, "node semantic")); this.provenance(asObject(value.provenance, "node provenance")); }
  operations(values: JsonObject[]): void {
    this.count(values.length);
    for (const value of values) {
      const op = requireString(value, "op"); this.string(op);
      switch (op) {
        case "put.geometry": this.geometry(asObject(value.geometry, "geometry")); break;
        case "put.material": this.material(asObject(value.material, "material")); break;
        case "create.node": this.node(asObject(value.node, "node")); break;
        case "remove.node": this.string(requireString(value, "nodeId")); break;
        case "set.transform": this.string(requireString(value, "nodeId")); this.transform(asObject(value.transform, "transform")); break;
        case "set.geometry": this.string(requireString(value, "nodeId")); this.optionalString(optionalString(value, "geometryId")); break;
        case "set.material": this.string(requireString(value, "nodeId")); this.optionalString(optionalString(value, "materialId")); break;
        case "set.visibility": this.string(requireString(value, "nodeId")); this.byte(booleanField(value, "isVisible") ? 1 : 0); break;
        default: throw new ProtocolError(`unsupported canonical operation: ${op}`, "proposal_rejected");
      }
    }
  }
}

function operationArray(value: JsonObject): JsonObject[] { return requireArray(value, "operations", 128).map((item) => asObject(item, "operation")); }
function vector(value: unknown, length: number): number[] { if (!Array.isArray(value) || value.length !== length || !value.every(isNumber)) throw new ProtocolError(`expected ${length}-element numeric vector`, "proposal_rejected"); return value; }
function numberField(object: JsonObject, key: string): number { const value = object[key]; if (!isNumber(value)) throw new ProtocolError(`${key} must be a finite number`, "proposal_rejected"); return value; }
function integerFieldOr(object: JsonObject, key: string, fallback: number): number { const value = object[key]; if (value === null || value === undefined) return fallback; if (!isNumber(value) || !Number.isInteger(value)) throw new ProtocolError(`${key} must be an integer`, "proposal_rejected"); return value; }
function numericArray(object: JsonObject, key: string, exactLength: number): number[] { const value = object[key]; if (!Array.isArray(value) || value.length !== exactLength || !value.every(isNumber)) throw new ProtocolError(`${key} must be a ${exactLength}-number array`, "proposal_rejected"); return value; }
function stringArray(object: JsonObject, key: string, max: number): string[] { const value = requireArray(object, key, max); if (!value.every(isString)) throw new ProtocolError(`${key} must be strings`, "proposal_rejected"); return value as string[]; }
function optionalString(object: JsonObject, key: string): string | null { const value = object[key]; if (value === undefined || value === null) return null; if (!isString(value)) throw new ProtocolError(`${key} must be string or null`, "proposal_rejected"); return value; }
function booleanField(object: JsonObject, key: string): boolean { const value = object[key]; if (typeof value !== "boolean") throw new ProtocolError(`${key} must be boolean`, "proposal_rejected"); return value; }
function enumField(object: JsonObject, key: string, allowed: string[]): string { const value = requireString(object, key); if (!allowed.includes(value)) throw new ProtocolError(`${key} is invalid`, "proposal_rejected"); return value; }
function canonicalTransform(value: JsonObject): JsonObject { return { translation: vector(value.translation, 3), rotation: vector(value.rotation, 4), scale: vector(value.scale, 3) }; }
function normalizeRecipe(value: JsonObject): JsonObject {
  const kind = requireString(value, "kind");
  switch (kind) {
    case "box": return { kind, size: vector(value.size, 3) };
    case "sphere": return { kind, radius: numberField(value, "radius"), segments: integerFieldOr(value, "segments", 24) };
    case "cylinder": return { kind, radius: numberField(value, "radius"), height: numberField(value, "height"), radialSegments: integerFieldOr(value, "radialSegments", 24) };
    case "cone": return { kind, bottomRadius: numberField(value, "bottomRadius"), topRadius: numberField(value, "topRadius"), height: numberField(value, "height"), radialSegments: integerFieldOr(value, "radialSegments", 24) };
    case "tube": return { kind, points: requireArray(value, "points", 256).map((point) => vector(point, 3)), radius: numberField(value, "radius"), radialSegments: integerFieldOr(value, "radialSegments", 12) };
    case "arrow": return { kind, start: vector(value.start, 3), end: vector(value.end, 3), shaftRadius: numberField(value, "shaftRadius"), headRadius: numberField(value, "headRadius"), headLength: numberField(value, "headLength"), radialSegments: integerFieldOr(value, "radialSegments", 16) };
    default: throw new ProtocolError(`unsupported geometry recipe: ${kind}`, "proposal_rejected");
  }
}

function stableId(kind: string, requestId: string, alias: string): string {
  const digest = createHash("sha256").update(`${requestId}\u0000${kind}\u0000${alias}`).digest("hex").slice(0, 24);
  return `${kind}_${digest}`;
}
