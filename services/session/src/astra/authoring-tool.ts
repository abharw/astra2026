import { JsonObject } from "../json.js";

const vector3 = { type: "array", minItems: 3, maxItems: 3, items: { type: "number" } };
const quaternion = { type: "array", minItems: 4, maxItems: 4, items: { type: "number" } };
const nullableString = {
  anyOf: [{ type: "string", minLength: 1, maxLength: 256 }, { type: "null" }]
};
const transform = {
  type: "object",
  additionalProperties: false,
  required: ["translation", "rotation", "scale"],
  properties: { translation: vector3, rotation: quaternion, scale: vector3 }
};

const recipe = {
  anyOf: [
    { type: "object", additionalProperties: false, required: ["kind", "size"], properties: { kind: { type: "string", const: "box" }, size: vector3 } },
    { type: "object", additionalProperties: false, required: ["kind", "radius", "segments"], properties: { kind: { type: "string", const: "sphere" }, radius: { type: "number" }, segments: { type: "integer" } } },
    { type: "object", additionalProperties: false, required: ["kind", "radius", "height", "radialSegments"], properties: { kind: { type: "string", const: "cylinder" }, radius: { type: "number" }, height: { type: "number" }, radialSegments: { type: "integer" } } },
    { type: "object", additionalProperties: false, required: ["kind", "bottomRadius", "topRadius", "height", "radialSegments"], properties: { kind: { type: "string", const: "cone" }, bottomRadius: { type: "number" }, topRadius: { type: "number" }, height: { type: "number" }, radialSegments: { type: "integer" } } },
    { type: "object", additionalProperties: false, required: ["kind", "points", "radius", "radialSegments"], properties: { kind: { type: "string", const: "tube" }, points: { type: "array", minItems: 2, maxItems: 256, items: vector3 }, radius: { type: "number" }, radialSegments: { type: "integer" } } },
    { type: "object", additionalProperties: false, required: ["kind", "start", "end", "shaftRadius", "headRadius", "headLength", "radialSegments"], properties: { kind: { type: "string", const: "arrow" }, start: vector3, end: vector3, shaftRadius: { type: "number" }, headRadius: { type: "number" }, headLength: { type: "number" }, radialSegments: { type: "integer" } } }
  ]
};

const material = {
  type: "object",
  additionalProperties: false,
  required: ["baseColorLinear", "metallic", "roughness"],
  properties: {
    baseColorLinear: { type: "array", minItems: 4, maxItems: 4, items: { type: "number" } },
    metallic: { type: "number" },
    roughness: { type: "number" }
  }
};

const node = {
  type: "object",
  additionalProperties: false,
  required: ["parentAlias", "geometryAlias", "materialAlias", "transform", "isVisible", "semantic", "provenance"],
  properties: {
    parentAlias: nullableString,
    geometryAlias: nullableString,
    materialAlias: nullableString,
    transform,
    isVisible: { type: "boolean" },
    semantic: { type: "object", additionalProperties: false, required: ["name", "role", "description"], properties: { name: { type: "string", minLength: 1, maxLength: 512 }, role: nullableString, description: nullableString } },
    provenance: { type: "object", additionalProperties: false, required: ["origin", "factualSupport", "sourceRefs"], properties: { origin: { type: "string", enum: ["authored", "generated", "imported"] }, factualSupport: { type: "string", enum: ["illustrative", "referenceBased"] }, sourceRefs: { type: "array", maxItems: 64, items: { type: "string" } } } }
  }
};

const operation = {
  anyOf: [
    { type: "object", additionalProperties: false, required: ["kind", "alias", "recipe"], properties: { kind: { type: "string", const: "geometry" }, alias: { type: "string", minLength: 1, maxLength: 64 }, recipe } },
    { type: "object", additionalProperties: false, required: ["kind", "alias", "material"], properties: { kind: { type: "string", const: "material" }, alias: { type: "string", minLength: 1, maxLength: 64 }, material } },
    { type: "object", additionalProperties: false, required: ["kind", "alias", "node"], properties: { kind: { type: "string", const: "node" }, alias: { type: "string", minLength: 1, maxLength: 64 }, node } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "transform"], properties: { kind: { type: "string", const: "setTransform" }, nodeRef: { type: "string" }, transform } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "geometryAlias"], properties: { kind: { type: "string", const: "setGeometry" }, nodeRef: { type: "string" }, geometryAlias: nullableString } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "materialAlias"], properties: { kind: { type: "string", const: "setMaterial" }, nodeRef: { type: "string" }, materialAlias: nullableString } },
    { type: "object", additionalProperties: false, required: ["kind", "nodeRef", "visible"], properties: { kind: { type: "string", const: "setVisibility" }, nodeRef: { type: "string" }, visible: { type: "boolean" } } }
  ]
};

export const ASTRA_AUTHORING_TOOL = {
  type: "function",
  name: "propose_scene",
  description: "Propose one bounded, editable scene creation or patch. The application normalizes aliases and validates every operation before device installation.",
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
