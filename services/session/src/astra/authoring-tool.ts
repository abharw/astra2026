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
