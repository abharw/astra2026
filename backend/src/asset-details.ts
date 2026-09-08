import { JsonObject, ProtocolError, asObject, isNumber, isObject, isString, rejectUnknown, requireArray, requireInteger, requireString } from "./json.js";

/** Host-advertised source structure; empty targets retain reference poses without authorizing expansion. */
export interface AvailableAssetDetail {
  detailId: string;
  targetNodeIds: string[];
  name: string;
  description?: string;
  assetID: string;
  byteCount: number;
  triangleCount: number;
  children: AssetDetailChild[];
}

export interface AssetDetailChild {
  partID: string;
  transform: JsonObject;
  semantic: JsonObject;
  provenance: JsonObject;
}

export function parseAvailableAssetDetails(value: unknown, document: JsonObject): AvailableAssetDetail[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 32) throw new ProtocolError("availableAssetDetails must contain at most 32 templates");
  if (Buffer.byteLength(JSON.stringify(value), "utf8") > 128 * 1024) throw new ProtocolError("availableAssetDetails exceeds 128 KiB");
  const nodes = new Map((Array.isArray(document.nodes) ? document.nodes.filter(isObject) : []).map((node) => [node.nodeId, node]));
  const referencedGeometryIds = new Set([...nodes.values()].map((node) => node.geometryId).filter(isString));
  const referencedAssetIds = new Set((Array.isArray(document.geometryDefinitions) ? document.geometryDefinitions.filter(isObject) : [])
    .filter((geometry) => referencedGeometryIds.has(geometry.geometryId as string))
    .flatMap((geometry) => isObject(geometry.recipe) && geometry.recipe.kind === "importedAsset" && isString(geometry.recipe.assetID) ? [geometry.recipe.assetID] : []));
  const detailIds = new Set<string>();
  return value.map((raw) => {
    const detail = asObject(raw, "available asset detail");
    rejectUnknown(detail, ["detailId", "targetNodeIds", "name", "description", "assetID", "byteCount", "triangleCount", "children"]);
    const detailId = requireString(detail, "detailId", 128);
    if (detailIds.has(detailId)) throw new ProtocolError("duplicate detailId");
    detailIds.add(detailId);
    const targetNodeIds = strings(detail, "targetNodeIds", 128, 128);
    if (new Set(targetNodeIds).size !== targetNodeIds.length) throw new ProtocolError("targetNodeIds must be unique");
    for (const id of targetNodeIds) {
      const node = nodes.get(id);
      if (!node || !isString(node.geometryId) || !node.geometryId.length) throw new ProtocolError("asset detail target must be an observed node with geometry");
    }
    const assetID = requireString(detail, "assetID", 71);
    if (!/^sha256:[a-f0-9]{64}$/.test(assetID)) throw new ProtocolError("assetID must be a SHA-256 content identifier");
    if (!targetNodeIds.length && !referencedAssetIds.has(assetID)) throw new ProtocolError("reference-only detail must describe an asset used by the accepted scene");
    const byteCount = requireInteger(detail, "byteCount");
    const triangleCount = requireInteger(detail, "triangleCount");
    if (byteCount < 1 || byteCount > 128 * 1024 * 1024 || triangleCount > 2_000_000) throw new ProtocolError("asset detail resource exceeds admission limits");
    const children = requireArray(detail, "children", 32).map(parseChild);
    if (!children.length || new Set(children.map((child) => child.partID)).size !== children.length) throw new ProtocolError("detail children must be nonempty with unique partIDs");
    const description = optionalText(detail, "description", 2_048);
    return { detailId, targetNodeIds, name: requireString(detail, "name", 256), ...(description === undefined ? {} : { description }), assetID, byteCount, triangleCount, children };
  });
}

function parseChild(value: unknown): AssetDetailChild {
  const child = asObject(value, "asset detail child");
  rejectUnknown(child, ["partID", "transform", "semantic", "provenance"]);
  const transform = asObject(child.transform, "detail transform");
  rejectUnknown(transform, ["translation", "rotation", "scale"]);
  const translation = vector(transform.translation, 3);
  const rotation = vector(transform.rotation, 4);
  const scale = vector(transform.scale, 3);
  if (translation.some((n) => Math.abs(n) > 10_000) || scale.some((n) => n <= 0 || n > 1_000) || Math.abs(rotation.reduce((sum, n) => sum + n * n, 0) - 1) > 0.0001) throw new ProtocolError("detail transform is outside coordinate, scale or unit-quaternion bounds");
  const semantic = asObject(child.semantic, "detail semantic");
  rejectUnknown(semantic, ["name", "role", "description"]);
  const role = optionalText(semantic, "role", 256);
  const description = optionalText(semantic, "description", 2_048);
  const provenance = asObject(child.provenance, "detail provenance");
  rejectUnknown(provenance, ["origin", "factualSupport", "sourceRefs"]);
  const origin = requireString(provenance, "origin", 32);
  const factualSupport = requireString(provenance, "factualSupport", 32);
  if (!["authored", "generated", "imported"].includes(origin) || !["illustrative", "referenceBased"].includes(factualSupport)) throw new ProtocolError("detail provenance is invalid");
  return {
    partID: requireString(child, "partID", 128), transform: { translation, rotation, scale },
    semantic: { name: requireString(semantic, "name", 256), ...(role === undefined ? {} : { role }), ...(description === undefined ? {} : { description }) },
    provenance: { origin, factualSupport, sourceRefs: strings(provenance, "sourceRefs", 16, 1_024) }
  };
}

function strings(object: JsonObject, key: string, maxItems: number, maxLength: number): string[] {
  const values = requireArray(object, key, maxItems);
  if (!values.every((v) => isString(v) && v.length > 0 && v.length <= maxLength)) throw new ProtocolError(`${key} contains an invalid string`);
  return values as string[];
}
function optionalText(object: JsonObject, key: string, max: number): string | undefined {
  if (object[key] === undefined || object[key] === null) return undefined;
  return requireString(object, key, max);
}
function vector(value: unknown, length: number): number[] {
  if (!Array.isArray(value) || value.length !== length || !value.every(isNumber)) throw new ProtocolError(`detail transform requires a finite ${length}-vector`);
  return value;
}
