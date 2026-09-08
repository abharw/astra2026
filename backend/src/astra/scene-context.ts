import { JsonObject, JsonValue, isObject } from "../json.js";

/** A model view, not a replacement document. IDs, poses and hierarchy stay exact. */
export function sceneContext(document: JsonObject): JsonObject {
  const scene = structuredClone(document);
  const descriptions = new RepeatedValues("description");
  const provenances = new RepeatedValues("provenance");
  const assets = new RepeatedValues("asset");
  const nodes = Array.isArray(scene.nodes) ? scene.nodes.filter(isObject) : [];
  const geometries = Array.isArray(scene.geometryDefinitions) ? scene.geometryDefinitions.filter(isObject) : [];

  for (const node of nodes) {
    if (isObject(node.semantic) && typeof node.semantic.description === "string") descriptions.observe(node.semantic.description);
    if (isObject(node.provenance)) provenances.observe(node.provenance);
  }
  for (const geometry of geometries) {
    if (isObject(geometry.recipe) && geometry.recipe.kind === "importedAsset" && typeof geometry.recipe.assetID === "string") assets.observe(geometry.recipe.assetID);
  }
  for (const node of nodes) {
    if (isObject(node.semantic)) descriptions.replace(node.semantic, "description", "descriptionRef");
    provenances.replace(node, "provenance", "provenanceRef");
  }
  for (const geometry of geometries) {
    // Hashes authenticate the native document; the model can only use geometryId.
    // Keep recipes and every geometry, including currently unreferenced definitions.
    delete geometry.contentHash;
    if (isObject(geometry.recipe) && geometry.recipe.kind === "importedAsset") assets.replace(geometry.recipe, "assetID", "assetRef");
  }
  return { format: "astra-scene-context/v1", shared: { descriptions: descriptions.values, provenances: provenances.values, assets: assets.values }, scene };
}

/** Factor repeated metadata without truncating strings, numbers, nodes or edges. */
class RepeatedValues {
  readonly values: JsonObject = {};
  private counts = new Map<string, number>();
  private references = new Map<string, string>();
  constructor(private readonly prefix: string) {}

  observe(value: JsonValue): void {
    const key = JSON.stringify(value);
    this.counts.set(key, (this.counts.get(key) ?? 0) + 1);
  }

  replace(object: JsonObject, field: string, referenceField: string): void {
    const value = object[field];
    if (value === undefined) return;
    const key = JSON.stringify(value);
    if ((this.counts.get(key) ?? 0) < 2) return;
    let reference = this.references.get(key);
    if (!reference) {
      reference = `${this.prefix}_${this.references.size + 1}`;
      this.references.set(key, reference);
      this.values[reference] = value;
    }
    delete object[field];
    object[referenceField] = reference;
  }
}
