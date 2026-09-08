import { JsonObject } from "../json.js";

const coordinate = { type: "number", minimum: -10_000, maximum: 10_000 };
const dimension = { type: "number", exclusiveMinimum: 0, maximum: 1_000 };
const unitInterval = { type: "number", minimum: 0, maximum: 1 };
const segmentCount = { type: "integer", minimum: 3, maximum: 256, description: "Use low tessellation appropriate to an AR teaching visual, usually 12–24." };
const vector3 = { type: "array", minItems: 3, maxItems: 3, items: coordinate };
const positiveVector3 = { type: "array", minItems: 3, maxItems: 3, items: dimension };
const quaternion = { type: "array", minItems: 4, maxItems: 4, items: { type: "number", minimum: -1, maximum: 1 }, description: "Unit quaternion [x,y,z,w]. Preserve observed rotation for translation-only edits." };
const nullableString = {
  anyOf: [{ type: "string", minLength: 1, maxLength: 256 }, { type: "null" }]
};
const transform = {
  type: "object",
  additionalProperties: false,
  required: ["translation", "rotation", "scale"],
  properties: { translation: { ...vector3, description: "Absolute position in parent coordinates, in metres before ancestor scales." }, rotation: quaternion, scale: positiveVector3 }
};

const recipe = {
  anyOf: [
    { type: "object", additionalProperties: false, required: ["kind", "size"], properties: { kind: { type: "string", const: "box" }, size: positiveVector3 } },
    { type: "object", additionalProperties: false, required: ["kind", "radius", "segments"], properties: { kind: { type: "string", const: "sphere" }, radius: dimension, segments: segmentCount } },
    { type: "object", additionalProperties: false, required: ["kind", "radius", "height", "radialSegments"], properties: { kind: { type: "string", const: "cylinder" }, radius: dimension, height: dimension, radialSegments: segmentCount } },
    { type: "object", additionalProperties: false, required: ["kind", "bottomRadius", "topRadius", "height", "radialSegments"], properties: { kind: { type: "string", const: "cone" }, bottomRadius: { type: "number", minimum: 0, maximum: 1_000 }, topRadius: { type: "number", minimum: 0, maximum: 1_000 }, height: dimension, radialSegments: segmentCount } },
    { type: "object", additionalProperties: false, required: ["kind", "points", "radius", "radialSegments"], properties: { kind: { type: "string", const: "tube" }, points: { type: "array", minItems: 2, maxItems: 256, items: vector3 }, radius: dimension, radialSegments: segmentCount } },
    { type: "object", additionalProperties: false, required: ["kind", "start", "end", "shaftRadius", "headRadius", "headLength", "radialSegments"], properties: { kind: { type: "string", const: "arrow" }, start: vector3, end: vector3, shaftRadius: dimension, headRadius: dimension, headLength: { ...dimension, description: "Must not exceed the start-to-end distance." }, radialSegments: segmentCount } }
  ]
};

const material = {
  type: "object",
  additionalProperties: false,
  required: ["baseColorLinear", "metallic", "roughness"],
  properties: {
    baseColorLinear: { type: "array", minItems: 4, maxItems: 4, items: unitInterval, description: "Linear [red,green,blue,alpha]; alpha must be exactly 1." },
    metallic: unitInterval,
    roughness: unitInterval
  }
};

const node = {
  type: "object",
  additionalProperties: false,
  required: ["parentAlias", "geometryAlias", "materialAlias", "transform", "isVisible", "semantic"],
  properties: {
    parentAlias: nullableString,
    geometryAlias: nullableString,
    materialAlias: nullableString,
    transform,
    isVisible: { type: "boolean" },
    semantic: { type: "object", additionalProperties: false, required: ["name", "role", "description"], properties: { name: { type: "string", minLength: 1, maxLength: 256, description: "Short human-readable part name, at most 256 UTF-8 bytes." }, role: nullableString, description: nullableString } }
  }
};

const operation = {
  anyOf: [
    { type: "object", additionalProperties: false, required: ["kind", "alias", "recipe"], properties: { kind: { type: "string", const: "geometry" }, alias: { type: "string", minLength: 1, maxLength: 64 }, recipe } },
    { type: "object", additionalProperties: false, required: ["kind", "alias", "material"], properties: { kind: { type: "string", const: "material" }, alias: { type: "string", minLength: 1, maxLength: 64 }, material } },
    { type: "object", additionalProperties: false, required: ["kind", "alias", "node"], properties: { kind: { type: "string", const: "node" }, alias: { type: "string", minLength: 1, maxLength: 64 }, node } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "offset"], properties: { kind: { type: "string", const: "translate" }, nodeRef: { type: "string", description: "Exact observed node ID; new aliases are not supported by translate." }, offset: { ...vector3, description: "Translation offset in the node parent coordinate system, in metres before ancestor scales. Preserves current rotation and scale; moving a parent carries its children." } } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "detailId"], properties: { kind: { type: "string", const: "expandDetail" }, nodeRef: { type: "string", minLength: 1, maxLength: 128, description: "Exact observed instance in the selected template's targetNodeIds." }, detailId: { type: "string", minLength: 1, maxLength: 128, description: "Exact advertised availableAssetDetails.detailId. In patch mode, replaces only the instance exterior with this template's immediate children, preserving its pose, identity, visibility and existing child edges. These children become addressable after installation in the next snapshot. Costs 2 + 2*childCount normalized operations; entire patch must fit 128." } } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "transform"], properties: { kind: { type: "string", const: "setTransform" }, nodeRef: { type: "string" }, transform } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "geometryAlias"], properties: { kind: { type: "string", const: "setGeometry" }, nodeRef: { type: "string" }, geometryAlias: nullableString } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "materialAlias"], properties: { kind: { type: "string", const: "setMaterial" }, nodeRef: { type: "string" }, materialAlias: nullableString } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "visible"], properties: { kind: { type: "string", const: "setVisibility" }, nodeRef: { type: "string" }, visible: { type: "boolean" } } }
  ]
};

const flowEndpoint = {
  type: "object",
  additionalProperties: false,
  required: ["nodeId", "localPoint"],
  properties: {
    nodeId: { type: "string", minLength: 1, maxLength: 128, description: "Exact observed structural node ID. Never another flow, the annotation itself, or a descendant of the annotation." },
    localPoint: { ...vector3, description: "Attachment point in this endpoint node's own local coordinates, in metres before its or ancestor transforms. Use provided nodeLocalBounds; do not apply world transforms to this point." }
  }
};

const flowProperties = {
  source: flowEndpoint,
  target: flowEndpoint,
  routePoints: { type: "array", minItems: 0, maxItems: 8, items: vector3, description: "Optional intermediate waypoints in the annotation node's own local coordinates, excluding endpoints. The renderer supplies a smooth bounded path; use [] for a direct path." },
  direction: { type: "string", enum: ["forward", "reverse"], description: "forward moves from source to target; reverse moves from target to source without rebinding endpoints." },
  width: { type: "number", minimum: 0.001, maximum: 0.25, description: "Path width in annotation-local metres; size relative to the surrounding structure and account for ancestor scales." },
  label: { type: "string", maxLength: 80, description: "Short teaching label, at most 80 UTF-8 bytes; empty string means no label." },
  animated: { type: "boolean", description: "Whether the renderer may move direction markers; device Reduce Motion can disable markers while keeping the path and label." }
};

const flowRecipe = {
  type: "object",
  additionalProperties: false,
  required: ["kind", ...Object.keys(flowProperties)],
  properties: { kind: { type: "string", const: "flow" }, ...flowProperties }
};

const flowOperation = {
  type: "object",
  additionalProperties: false,
  required: ["kind", "alias", "parentNodeRef", ...Object.keys(flowProperties), "color"],
  properties: {
    kind: { type: "string", const: "flow" },
    alias: { type: "string", minLength: 1, maxLength: 64 },
    parentNodeRef: { anyOf: [{ type: "string", minLength: 1, maxLength: 128 }, { type: "null" }], description: "Exact observed parent node ID or previously defined node alias; null means scene root. For scoped generation, use scopeParentNodeId or a new node nested beneath it. The new annotation has an identity local transform, so its route points use that parent's coordinates." },
    ...flowProperties,
    color: { type: "array", minItems: 4, maxItems: 4, items: unitInterval, description: "Linear [red,green,blue,alpha] for the unlit path; alpha must be exactly 1." }
  }
};

export const ASTRA_AUTHORING_TOOL = {
  type: "function",
  name: "propose_scene",
  description: "Propose one bounded, editable scene creation or patch. Use translate for existing-part movement; code preserves rotation and scale. New nodes receive generated/illustrative provenance automatically. The application normalizes aliases and validates every operation before device installation.",
  strict: true,
  parameters: {
    type: "object",
    additionalProperties: false,
    required: ["mode", "explanation", "scopeParentNodeId", "operations"],
    properties: {
      mode: { type: "string", enum: ["generation", "patch", "explanation"] },
      explanation: { type: "string", minLength: 1, maxLength: 1_000 },
      scopeParentNodeId: nullableString,
      operations: { type: "array", minItems: 0, maxItems: 128, items: operation }
    }
  }
} as unknown as JsonObject;

/** Each capability extends a copy; legacy and image-only requests stay stable. */
export function authoringTool(illustrationEnabled = false, flowEnabled = false): JsonObject {
  if (!illustrationEnabled && !flowEnabled) return ASTRA_AUTHORING_TOOL;
  const tool = structuredClone(ASTRA_AUTHORING_TOOL);
  const parameters = tool.parameters as JsonObject;
  const properties = parameters.properties as JsonObject;
  if (flowEnabled) {
    const operations = properties.operations as JsonObject;
    const operationAlternatives = (operations.items as JsonObject).anyOf as JsonObject[];
    const geometryOperation = operationAlternatives.find((candidate) => ((candidate.properties as JsonObject).kind as JsonObject).const === "geometry")!;
    const recipes = ((geometryOperation.properties as JsonObject).recipe as JsonObject).anyOf as JsonObject[];
    recipes.push(structuredClone(flowRecipe) as unknown as JsonObject);
    operationAlternatives.push(structuredClone(flowOperation) as unknown as JsonObject, {
      type: "object", additionalProperties: false, required: ["kind", "nodeRef"],
      properties: { kind: { type: "string", const: "removeNode" }, nodeRef: { type: "string", minLength: 1, maxLength: 128, description: "Exact observed node ID to remove. The backend also removes its incident observed relationships. Node removal is not recursive: explicitly remove every descendant and any flow annotations bound to removed structural nodes in the same patch." } }
    });
  }
  if (!illustrationEnabled) return tool;
  parameters.required = [...parameters.required as string[], "illustration"];
  properties.illustration = {
    description: "A generated teaching illustration for observed components, or null. Only use with explanation mode, zero operations and null scopeParentNodeId. An illustration is not a measured observation or an installed scene edit.",
    anyOf: [
      {
        type: "object",
        additionalProperties: false,
        required: ["brief", "componentNodeIds", "sourceArtifactId"],
        properties: {
          brief: { type: "string", minLength: 1, maxLength: 2_000, description: "At most 2000 UTF-8 bytes. Describe the teaching objective, diagram or cutaway composition, labels and any requested refinement. Distinguish general illustrative content from observed source facts." },
          componentNodeIds: { type: "array", minItems: 1, maxItems: 16, items: { type: "string", minLength: 1, maxLength: 128 }, description: "One to sixteen unique exact node IDs observed in acceptedScene. Bind the illustration to the relevant selected components, never invented internal parts." },
          sourceArtifactId: { anyOf: [{ type: "string", minLength: 1, maxLength: 128 }, { type: "null" }], description: "For refinement, the exact artifactId from recentIllustrations. Otherwise null. Never use a URL, file path or an invented artifact ID." }
        }
      },
      { type: "null" }
    ]
  };
  return tool;
}
