import { createHash } from "node:crypto";
import { JsonObject, ProtocolError, asObject, isNumber, isString, requireArray, requireString } from "./json.js";
import { AvailableAssetDetail } from "./asset-details.js";

export interface IllustrationIntent {
  brief: string;
  componentNodeIds: string[];
  sourceArtifactId: string | null;
}

export interface AuthoringProposal {
  mode: "generation" | "patch" | "explanation";
  explanation: string;
  scopeParentNodeId: string | null;
  operations: JsonObject[];
  illustration?: IllustrationIntent | null;
}

export interface NormalizedProposal {
  mode: "generation" | "patch" | "explanation";
  explanation: string;
  scopeParentNodeId?: string;
  operations: JsonObject[];
  illustration?: IllustrationIntent;
}

export interface NormalizationOptions {
  flowEnabled?: boolean;
  observedGeometries?: ReadonlyMap<string, JsonObject>;
  observedRelationships?: readonly JsonObject[];
}

/**
 * Resolves model-local aliases to deterministic IDs. The emitted operation tags
 * deliberately match the portable v1 contract; native code remains authority
 * for semantic validity and installation.
 */
export function normalizeProposal(requestId: string, proposal: AuthoringProposal, observedNodeIds: Set<string>, observedGeometryIds: Set<string> = new Set(), observedNodes: ReadonlyMap<string, JsonObject> = new Map(), availableAssetDetails: readonly AvailableAssetDetail[] = [], options: NormalizationOptions = {}): NormalizedProposal {
  const aliases = new Map<string, string>();
  const workingTransforms = new Map<string, JsonObject>();
  const createdNodeIds = new Set<string>();
  const changedGeometryNodeIds = new Set<string>();
  const expandedNodeIds = new Set<string>();
  const emittedDetailGeometries = new Set<string>();
  const removedRelationshipIds = new Set<string>();
  const operationCount = proposal.operations.length;
  if (operationCount > 128 || (proposal.mode === "explanation" && operationCount !== 0) || (proposal.mode !== "explanation" && operationCount === 0)) {
    throw new ProtocolError("explanations require zero operations; mutations require 1-128 operations", "proposal_rejected");
  }
  if (proposal.mode === "explanation" && proposal.scopeParentNodeId !== null) throw new ProtocolError("explanations cannot reserve a generation scope", "proposal_rejected");
  let illustration: IllustrationIntent | undefined;
  if (proposal.illustration !== undefined && proposal.illustration !== null) {
    if (proposal.mode !== "explanation") throw new ProtocolError("illustrations require explanation mode with zero operations", "proposal_rejected");
    illustration = parseIllustrationIntent(proposal.illustration);
    if (illustration.componentNodeIds.some((nodeId) => !observedNodeIds.has(nodeId))) throw new ProtocolError("illustration components must be observed node IDs", "proposal_rejected");
  }
  const resolve = (value: unknown, kind: "node" | "geometry" | "material", allowObserved = false): string => {
    if (!isString(value) || value.length === 0 || value.length > 128) throw new ProtocolError(`invalid ${kind} reference`, "proposal_rejected");
    const observedIds = kind === "node" ? observedNodeIds : kind === "geometry" ? observedGeometryIds : undefined;
    if (allowObserved && observedIds?.has(value)) return value;
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
        const recipe = normalizeRecipe(asObject(source.recipe, "geometry.recipe"), options.flowEnabled === true);
        operations.push({ op: "put.geometry", geometry: { geometryId, contentHash: geometryContentHash(recipe), recipe } });
        break;
      }
      case "flow": {
        if (!options.flowEnabled) throw new ProtocolError("flow requires the flow.v1 client capability", "proposal_rejected");
        const allowed = new Set(["kind", "alias", "parentNodeRef", "source", "target", "routePoints", "direction", "width", "label", "animated", "color"]);
        if (Object.keys(source).some((key) => !allowed.has(key))) throw new ProtocolError("unknown semantic flow property", "proposal_rejected");
        const nodeId = define(source.alias, "node");
        if (observedNodeIds.has(nodeId) || createdNodeIds.has(nodeId)) throw new ProtocolError("created node ID collides with an existing node", "proposal_rejected");
        createdNodeIds.add(nodeId);
        // The semantic operation expands to the same immutable definitions and
        // ordinary node lifecycle used by every other geometry.
        const geometryId = define(source.alias, "geometry");
        const materialId = define(source.alias, "material");
        const recipe = normalizeFlowRecipe({
          kind: "flow", source: source.source!, target: source.target!, routePoints: source.routePoints!,
          direction: source.direction!, width: source.width!, label: source.label!, animated: source.animated!
        });
        const color = numericArray(source, "color", 4);
        if (color.some((channel) => channel < 0 || channel > 1) || color[3] !== 1) throw new ProtocolError("flow color requires RGB channels in 0...1 and alpha 1", "proposal_rejected");
        const parentId = source.parentNodeRef === null ? null : resolve(source.parentNodeRef, "node", true);
        operations.push(
          { op: "put.geometry", geometry: { geometryId, contentHash: geometryContentHash(recipe), recipe } },
          { op: "put.material", material: { materialId, baseColorLinear: color, metallic: 0, roughness: 1 } },
          { op: "create.node", node: {
            nodeId, parentId, geometryId, materialId,
            transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }, isVisible: true,
            semantic: { name: recipe.label === "" ? "Flow" : recipe.label!, role: "flow", description: null },
            provenance: { origin: "generated", factualSupport: "illustrative", sourceRefs: [] }
          } }
        );
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
        if (observedNodeIds.has(nodeId) || createdNodeIds.has(nodeId)) throw new ProtocolError("created node ID collides with an existing node", "proposal_rejected");
        createdNodeIds.add(nodeId);
        const node = asObject(source.node, "node.node");
        const parentAlias = node.parentAlias;
        const parentId = parentAlias === null || parentAlias === undefined ? null : resolve(parentAlias, "node", true);
        const geometryAlias = node.geometryAlias;
        const materialAlias = node.materialAlias;
        const semantic = asObject(node.semantic, "node.semantic");
        // Legacy proposals may include provenance. New authoring calls omit it:
        // generated content cannot grant itself reference-backed status.
        if (node.provenance !== undefined) asObject(node.provenance, "node.provenance");
        const clean: JsonObject = {
          nodeId, parentId, geometryId: geometryAlias === null || geometryAlias === undefined ? null : resolve(geometryAlias, "geometry", true),
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
        const nodeId = resolve(source.nodeRef, "node", true);
        const transform = canonicalTransform(asObject(source.transform, "setTransform.transform"));
        workingTransforms.set(nodeId, transform);
        operations.push({ op: "set.transform", nodeId, transform });
        break;
      }
      case "translate": {
        const nodeId = resolve(source.nodeRef, "node", true);
        if (!observedNodeIds.has(nodeId)) throw new ProtocolError("translate requires an observed node ID", "proposal_rejected");
        const observed = observedNodes.get(nodeId);
        const current = workingTransforms.get(nodeId) ?? (observed && canonicalTransform(asObject(observed.transform, "observed transform")));
        if (!current) throw new ProtocolError("translate requires the observed node transform", "proposal_rejected");
        const translation = vector(current.translation, 3);
        const offset = vector(source.offset, 3);
        const position = translation.map((value, index) => value + offset[index]!);
        if (position.some((value) => !Number.isFinite(value) || Math.abs(value) > 10_000)) throw new ProtocolError("translated position exceeds coordinate bounds", "proposal_rejected");
        const transform = { ...current, translation: position };
        workingTransforms.set(nodeId, transform);
        operations.push({ op: "set.transform", nodeId, transform });
        break;
      }
      case "setGeometry": {
        const nodeId = resolve(source.nodeRef, "node", true);
        if (expandedNodeIds.has(nodeId)) throw new ProtocolError("cannot replace geometry of a node expanded in this proposal", "proposal_rejected");
        changedGeometryNodeIds.add(nodeId);
        operations.push({ op: "set.geometry", nodeId, geometryId: source.geometryAlias === null ? null : resolve(source.geometryAlias, "geometry", true) });
        break;
      }
      case "expandDetail": {
        if (proposal.mode !== "patch") throw new ProtocolError("expandDetail requires patch mode", "proposal_rejected");
        const nodeId = resolve(source.nodeRef, "node", true);
        const detailId = requireString(source, "detailId", 128);
        const detail = availableAssetDetails.find((value) => value.detailId === detailId && value.targetNodeIds.includes(nodeId));
        const observed = observedNodes.get(nodeId);
        if (!observedNodeIds.has(nodeId) || !detail || !observed || !isString(observed.geometryId)) throw new ProtocolError("detail is not available for this observed node", "proposal_rejected");
        if (expandedNodeIds.has(nodeId) || changedGeometryNodeIds.has(nodeId)) throw new ProtocolError("detail target was already expanded or its geometry changed", "proposal_rejected");
        if (!detail.children.length || detail.children.length > 32) throw new ProtocolError("detail template must contain 1-32 immediate children", "proposal_rejected");
        expandedNodeIds.add(nodeId);
        // The instance remains the assembly: retain its ID, pose, visibility and
        // existing child edges. Only its opaque exterior is replaced by children.
        operations.push({ op: "set.geometry", nodeId, geometryId: null }, { op: "set.material", nodeId, materialId: null });
        for (const child of detail.children) {
          const childId = detailNodeId(nodeId, detailId, child.partID);
          if (observedNodeIds.has(childId) || createdNodeIds.has(childId)) throw new ProtocolError("detail child ID collides with an existing node", "proposal_rejected");
          createdNodeIds.add(childId);
          const geometryId = stableId("geometry", detail.assetID, child.partID);
          const recipe = { kind: "importedAsset", assetID: detail.assetID, partID: child.partID };
          // Repeated instances share one immutable definition; native rejects a
          // preexisting ID whose content differs, exactly as for all put.geometry.
          if (!emittedDetailGeometries.has(geometryId)) {
            operations.push({ op: "put.geometry", geometry: { geometryId, contentHash: geometryContentHash(recipe), recipe } });
            emittedDetailGeometries.add(geometryId);
          }
          operations.push({ op: "create.node", node: {
            nodeId: childId, parentId: nodeId, geometryId, materialId: null,
            transform: canonicalTransform(child.transform), isVisible: true,
            semantic: structuredClone(child.semantic), provenance: structuredClone(child.provenance)
          } });
        }
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
      case "removeNode": {
        const nodeId = resolve(source.nodeRef, "node", true);
        for (const relationship of options.observedRelationships ?? []) {
          if (relationship.sourceNodeId !== nodeId && relationship.targetNodeId !== nodeId) continue;
          const relationshipId = requireString(relationship, "relationshipId", 128);
          if (!removedRelationshipIds.has(relationshipId)) {
            operations.push({ op: "remove.relationship", relationshipId });
            removedRelationshipIds.add(relationshipId);
          }
        }
        operations.push({ op: "remove.node", nodeId });
        break;
      }
      default: throw new ProtocolError(`unsupported authoring operation: ${kind}`, "proposal_rejected");
    }
    if (operations.length > 128) throw new ProtocolError("normalized proposal exceeds 128 operations; expand fewer instances per turn", "proposal_rejected");
  }
  if (proposal.mode === "generation" && proposal.scopeParentNodeId !== null && !observedNodeIds.has(proposal.scopeParentNodeId)) {
    throw new ProtocolError("generation scope parent was not observed", "proposal_rejected");
  }
  validateFlowCandidate(operations, observedNodeIds, observedNodes, options);
  return { mode: proposal.mode, explanation: proposal.explanation, scopeParentNodeId: proposal.scopeParentNodeId ?? undefined, operations, ...(illustration ? { illustration } : {}) };
}

/** Stable across turns and resource cache state, and scoped to one selected instance. */
export function detailNodeId(targetNodeId: string, detailId: string, partID: string): string {
  return stableId("node", targetNodeId, `${detailId}\u0000${partID}`);
}

export function parseAuthoringProposal(value: unknown): AuthoringProposal {
  const object = asObject(value, "model proposal");
  const mode = requireString(object, "mode", 32);
  if (mode !== "generation" && mode !== "patch" && mode !== "explanation") throw new ProtocolError("proposal mode must be generation, patch, or explanation", "proposal_rejected");
  const explanation = requireString(object, "explanation", 1_000);
  const scope = object.scopeParentNodeId;
  if (scope !== null && !isString(scope)) throw new ProtocolError("scopeParentNodeId must be string or null", "proposal_rejected");
  const operations = requireArray(object, "operations", 128).map((item) => asObject(item, "proposal operation"));
  const illustration = object.illustration === undefined || object.illustration === null ? object.illustration : parseIllustrationIntent(object.illustration);
  return { mode, explanation, scopeParentNodeId: scope, operations, ...(illustration !== undefined ? { illustration } : {}) };
}

function parseIllustrationIntent(value: unknown): IllustrationIntent {
  const object = asObject(value, "illustration");
  const allowed = new Set(["brief", "componentNodeIds", "sourceArtifactId"]);
  if (Object.keys(object).some((key) => !allowed.has(key))) throw new ProtocolError("unknown illustration property", "proposal_rejected");
  const brief = object.brief;
  if (typeof brief !== "string" || brief.trim().length === 0 || Buffer.byteLength(brief, "utf8") > 2_000) throw new ProtocolError("illustration brief must be non-empty and at most 2000 UTF-8 bytes", "proposal_rejected");
  const componentNodeIds = object.componentNodeIds;
  if (!Array.isArray(componentNodeIds) || componentNodeIds.length < 1 || componentNodeIds.length > 16 || !componentNodeIds.every((nodeId): nodeId is string => typeof nodeId === "string" && nodeId.length > 0 && nodeId.length <= 128) || new Set(componentNodeIds).size !== componentNodeIds.length) throw new ProtocolError("illustration components must be 1-16 unique node IDs", "proposal_rejected");
  const sourceArtifactId = object.sourceArtifactId;
  if (sourceArtifactId !== null && (typeof sourceArtifactId !== "string" || sourceArtifactId.length === 0 || sourceArtifactId.length > 128)) throw new ProtocolError("illustration sourceArtifactId must be a non-empty string up to 128 characters or null", "proposal_rejected");
  return { brief: brief.trim(), componentNodeIds: [...componentNodeIds], sourceArtifactId };
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
      case "flow": {
        const source = asObject(value.source, "flow.source"), target = asObject(value.target, "flow.target");
        this.string(requireString(source, "nodeId")); this.vec3(source.localPoint);
        this.string(requireString(target, "nodeId")); this.vec3(target.localPoint);
        const points = requireArray(value, "routePoints", 8); this.count(points.length); points.forEach((point) => this.vec3(point));
        this.string(enumField(value, "direction", ["forward", "reverse"])); this.double(numberField(value, "width"));
        if (typeof value.label !== "string") throw new ProtocolError("flow label must be a string", "proposal_rejected");
        this.string(value.label); this.byte(booleanField(value, "animated") ? 1 : 0); return;
      }
      case "importedAsset": this.string(requireString(value, "assetID")); this.string(requireString(value, "partID")); return;
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
        case "remove.relationship": this.string(requireString(value, "relationshipId")); break;
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
function normalizeRecipe(value: JsonObject, flowEnabled = false): JsonObject {
  const kind = requireString(value, "kind");
  switch (kind) {
    case "box": return { kind, size: vector(value.size, 3) };
    case "sphere": return { kind, radius: numberField(value, "radius"), segments: integerFieldOr(value, "segments", 24) };
    case "cylinder": return { kind, radius: numberField(value, "radius"), height: numberField(value, "height"), radialSegments: integerFieldOr(value, "radialSegments", 24) };
    case "cone": return { kind, bottomRadius: numberField(value, "bottomRadius"), topRadius: numberField(value, "topRadius"), height: numberField(value, "height"), radialSegments: integerFieldOr(value, "radialSegments", 24) };
    case "tube": return { kind, points: requireArray(value, "points", 256).map((point) => vector(point, 3)), radius: numberField(value, "radius"), radialSegments: integerFieldOr(value, "radialSegments", 12) };
    case "arrow": return { kind, start: vector(value.start, 3), end: vector(value.end, 3), shaftRadius: numberField(value, "shaftRadius"), headRadius: numberField(value, "headRadius"), headLength: numberField(value, "headLength"), radialSegments: integerFieldOr(value, "radialSegments", 16) };
    case "flow": {
      if (!flowEnabled) throw new ProtocolError("flow requires the flow.v1 client capability", "proposal_rejected");
      return normalizeFlowRecipe(value);
    }
    default: throw new ProtocolError(`unsupported geometry recipe: ${kind}`, "proposal_rejected");
  }
}

function normalizeFlowRecipe(value: JsonObject): JsonObject {
  const allowed = new Set(["kind", "source", "target", "routePoints", "direction", "width", "label", "animated"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) throw new ProtocolError("unknown flow recipe property", "proposal_rejected");
  const attachment = (raw: unknown, name: string): JsonObject => {
    const object = asObject(raw, `flow.${name}`);
    if (Object.keys(object).some((key) => key !== "nodeId" && key !== "localPoint")) throw new ProtocolError("unknown flow attachment property", "proposal_rejected");
    return { nodeId: requireString(object, "nodeId", 128), localPoint: flowPoint(object.localPoint) };
  };
  const source = attachment(value.source, "source"), target = attachment(value.target, "target");
  if (source.nodeId === target.nodeId && (source.localPoint as number[]).every((coordinate, index) => coordinate === (target.localPoint as number[])[index])) {
    throw new ProtocolError("flow attachments on the same node require distinct local points", "proposal_rejected");
  }
  const width = numberField(value, "width");
  if (width < 0.001 || width > 0.25) throw new ProtocolError("flow width must be between 0.001 and 0.25 metres", "proposal_rejected");
  if (typeof value.label !== "string" || Buffer.byteLength(value.label, "utf8") > 80) throw new ProtocolError("flow label must be at most 80 UTF-8 bytes", "proposal_rejected");
  return {
    kind: "flow", source, target, routePoints: requireArray(value, "routePoints", 8).map(flowPoint),
    direction: enumField(value, "direction", ["forward", "reverse"]), width, label: value.label, animated: booleanField(value, "animated")
  };
}

function flowPoint(value: unknown): number[] {
  const point = vector(value, 3);
  if (point.some((coordinate) => Math.abs(coordinate) > 10_000)) throw new ProtocolError("flow point exceeds coordinate bounds", "proposal_rejected");
  return [...point];
}

/** Validate the final candidate, so a bound part and its annotations can be
 * removed atomically in either order. Unused definitions have no node binding. */
function validateFlowCandidate(operations: readonly JsonObject[], observedNodeIds: ReadonlySet<string>, observedNodes: ReadonlyMap<string, JsonObject>, options: NormalizationOptions): void {
  const nodes = new Map<string, JsonObject>();
  for (const nodeId of observedNodeIds) nodes.set(nodeId, { ...(observedNodes.get(nodeId) ?? {}), nodeId });
  const recipes = new Map<string, JsonObject>();
  for (const [geometryId, geometry] of options.observedGeometries ?? []) recipes.set(geometryId, asObject(geometry.recipe, "observed geometry recipe"));
  const requireCapability = (geometryId: unknown): void => {
    if (!options.flowEnabled && typeof geometryId === "string" && recipes.get(geometryId)?.kind === "flow") {
      throw new ProtocolError("flow requires the flow.v1 client capability", "proposal_rejected");
    }
  };
  for (const operation of operations) {
    switch (operation.op) {
      case "put.geometry": {
        const geometry = asObject(operation.geometry, "geometry");
        const recipe = asObject(geometry.recipe, "geometry recipe");
        recipes.set(requireString(geometry, "geometryId"), recipe);
        requireCapability(geometry.geometryId);
        break;
      }
      case "create.node": {
        const node = asObject(operation.node, "node");
        requireCapability(node.geometryId);
        nodes.set(requireString(node, "nodeId"), node);
        break;
      }
      case "set.geometry": {
        requireCapability(operation.geometryId);
        const nodeId = requireString(operation, "nodeId"), node = nodes.get(nodeId);
        if (!node) throw new ProtocolError("cannot modify a removed node", "proposal_rejected");
        nodes.set(nodeId, { ...node, geometryId: operation.geometryId! });
        break;
      }
      case "remove.node": {
        if (!nodes.delete(requireString(operation, "nodeId"))) throw new ProtocolError("cannot remove a missing node", "proposal_rejected");
        break;
      }
      case "set.transform": case "set.material": case "set.visibility": {
        if (!nodes.has(requireString(operation, "nodeId"))) throw new ProtocolError("cannot modify a removed node", "proposal_rejected");
        break;
      }
    }
  }
  const flowNodes = new Map<string, JsonObject>();
  for (const [nodeId, node] of nodes) {
    const recipe = typeof node.geometryId === "string" ? recipes.get(node.geometryId) : undefined;
    if (recipe?.kind === "flow") flowNodes.set(nodeId, recipe);
  }
  if (flowNodes.size > 32) throw new ProtocolError("scene exceeds 32 flow instances", "proposal_rejected");
  if (flowNodes.size === 0 && !options.flowEnabled) return;

  // Validate hierarchy independently of geometry sharing. A definition that is
  // valid for one instance can bind to a descendant of another instance.
  const complete = new Set<string>();
  for (const nodeId of nodes.keys()) {
    const path = new Set<string>();
    let current: string | null = nodeId;
    while (current !== null && !complete.has(current)) {
      if (path.has(current)) throw new ProtocolError("flow candidate contains a hierarchy cycle", "proposal_rejected");
      const node = nodes.get(current);
      if (!node) throw new ProtocolError("flow candidate contains a missing parent", "proposal_rejected");
      path.add(current);
      current = optionalString(node, "parentId");
    }
    for (const visited of path) complete.add(visited);
  }
  for (const recipe of flowNodes.values()) {
    const normalized = normalizeFlowRecipe(recipe);
    for (const name of ["source", "target"]) {
      const endpointId = requireString(asObject(normalized[name], `flow.${name}`), "nodeId");
      if (!nodes.has(endpointId)) throw new ProtocolError(`flow endpoint does not exist: ${endpointId}`, "proposal_rejected");
      let current: string | null = endpointId;
      while (current !== null) {
        if (flowNodes.has(current)) throw new ProtocolError("flow endpoints must be structural nodes outside flow annotation subtrees", "proposal_rejected");
        current = optionalString(nodes.get(current)!, "parentId");
      }
    }
  }
}

function stableId(kind: string, requestId: string, alias: string): string {
  const digest = createHash("sha256").update(`${requestId}\u0000${kind}\u0000${alias}`).digest("hex").slice(0, 24);
  return `${kind}_${digest}`;
}
