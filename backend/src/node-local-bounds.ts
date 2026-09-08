import { JsonObject, ProtocolError, asObject, isObject, rejectUnknown, requireString } from "./json.js";

/** Host-measured local bounds, admitted with exactly the scene snapshot that owns them. */
export interface NodeLocalBounds {
  nodeId: string;
  minimum: number[];
  maximum: number[];
}

export function parseNodeLocalBounds(value: unknown, document: JsonObject): NodeLocalBounds[] {
  if (!Array.isArray(value) || value.length > 128) throw new ProtocolError("nodeLocalBounds must contain at most 128 measured records", "invalid_node_bounds");
  const nodes = Array.isArray(document.nodes) ? document.nodes.filter(isObject) : [];
  const observed = new Set(nodes.flatMap(node => typeof node.nodeId === "string" ? [node.nodeId] : []));
  const used = new Set<string>();
  return value.map(record => {
    const object = asObject(record, "nodeLocalBounds record");
    rejectUnknown(object, ["nodeId", "minimum", "maximum"]);
    const nodeId = requireString(object, "nodeId", 128);
    if (!observed.has(nodeId) || used.has(nodeId)) throw new ProtocolError("nodeLocalBounds must refer to unique nodes in the same snapshot", "invalid_node_bounds");
    used.add(nodeId);
    const minimum = finitePoint(object.minimum);
    const maximum = finitePoint(object.maximum);
    if (minimum.some((coordinate, index) => coordinate > maximum[index]!)) throw new ProtocolError("nodeLocalBounds minimum must not exceed maximum", "invalid_node_bounds");
    return { nodeId, minimum, maximum };
  });
}

function finitePoint(value: unknown): number[] {
  if (!Array.isArray(value) || value.length !== 3 || !value.every(coordinate => typeof coordinate === "number" && Number.isFinite(coordinate))) throw new ProtocolError("nodeLocalBounds coordinates must be finite three-vectors", "invalid_node_bounds");
  return [...value] as number[];
}
