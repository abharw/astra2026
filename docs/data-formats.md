# Data formats

2026-09-08 · Format design and implemented v1 boundary. Swift/TypeScript hashes, strict decoding, semantic validation, and live generation-to-reducer acceptance are verified. Native builds pass; physical pointing/voice acceptance is in progress. The normative current shape is [the contract](../framework/contract/README.md). Numeric limits below are initial engineering limits to test, not measured device capabilities.

## 1. Three representations

“Astra generates an asset” means it produces a description or program that our framework turns into editable spatial content. The model does not directly produce RealityKit objects or GPU buffers.

| Representation | v0 format | Responsibility |
| --- | --- | --- |
| Model authoring | One typed `propose_scene` tool result | Describe parts, repeated structures, relationships and changes compactly; PTC is future work |
| Normalized scene | Versioned UTF-8 JSON | Preserve identities, geometry recipes, materials, transforms, semantics and provenance |
| Runtime rendering | Swift values, mesh buffers and RealityKit resources | Construct geometry and render it on the device |
| Imported asset | `GeometryRecipe.importedAsset(assetID, partID)` plus approved host descriptor | Current native asset path; raw USDZ stays in the host catalog and is never model-provided |
| Future portable baked asset | Self-contained GLB 2.0 plus semantic manifest | Exchange generated meshes with other renderers, including a later Unity client |
| Checkpoint | Accepted scene JSON and references to immutable artifacts | Reconstruct content without rerunning the model |

Keep the normalized recipe after constructing a mesh. A mesh alone does not retain “this is a fan blade,” the intended dimensions, or the parameters needed to regenerate it.

## 2. Model authoring and normalization

Expose the same generic operations through direct tool calls and programmatic tool calling. A program can describe seven blades with a loop; a direct call can describe an instance array. Both produce the same intermediate representation, abbreviated **IR**. Neither interface bypasses validation. Generated programs execute only in the configured isolated authoring environment, never as downloaded Swift or JavaScript inside the universal app.

The model supplies local aliases for new objects and observed references for existing objects. Backend normalization resolves aliases, assigns persistent IDs, normalizes defaults and checks references. Bounded linear/radial array expansion remains an unimplemented authoring capability; the device currently receives explicit nodes and generic geometry recipes, without expressions or control flow. The backend assigns transport IDs and populates revision/epoch fields from the request's immutable admission record, never from the newest session state when a delayed result arrives. The model cannot grant itself a newer revision or choose an installation epoch.

Use [the contract README](../framework/contract/README.md) and [scene.schema.json](../framework/contract/scene.schema.json) as the current format references. The schema uses JSON Schema 2020-12 with closed tagged variants. Keep the provider-facing strict tool schema separate: a provider's supported schema subset is an adapter constraint, not the definition of the portable format. Schema checks establish structure; semantic checks establish acyclic hierarchy, valid references, affordable geometry and valid numbers. Additional JSON properties are allowed unless explicitly prohibited, so close each wire object deliberately. [JSON Schema object rules](https://json-schema.org/understanding-json-schema/reference/object).

## 3. Identity and document structure

| Field | Meaning |
| --- | --- |
| `documentId` | Stable identity of saved spatial content across launches |
| `sceneId` | Ephemeral identity of one live scene incarnation |
| `nodeId` | Stable identity of a selectable component within the document |
| `geometryId` | Opaque immutable-version identity, separate from the computed content hash |
| `materialId` | Identity of a separately defined material |
| `generationId` | One runtime generation operation producing one or more batches |
| `requestId` | One exact transport request, including its retry identity |

Nodes reference geometry and material separately. Many blade nodes can share one mesh while keeping independent transforms and selection. Geometry changes create a new definition and replace the selected reference; moving an instance does not rebuild its mesh. Parent-child edges express containment. Separate typed relationships express concepts such as airflow or electrical connection without distorting that hierarchy.

This valid JSON illustrates a recipe body. It intentionally omits application-computed hashes and transport metadata; it is not a complete wire message or a verified generated artifact.

```json
{
  "schemaVersion": 1,
  "geometrySemanticsVersion": 1,
  "documentId": "document_demo",
  "geometryDefinitions": [
    {
      "geometryId": "geometry_chassis",
      "recipe": {
        "kind": "box",
        "size": [0.44, 0.09, 0.6]
      }
    }
  ],
  "materials": [
    {
      "materialId": "material_metal",
      "baseColorLinear": [0.12, 0.12, 0.14, 1],
      "metallic": 0.7,
      "roughness": 0.45
    }
  ],
  "nodes": [
    {
      "nodeId": "node_chassis",
      "parentId": null,
      "geometryId": "geometry_chassis",
      "materialId": "material_metal",
      "transform": {
        "translation": [0, 0.045, 0],
        "rotation": [0, 0, 0, 1],
        "scale": [1, 1, 1]
      },
      "isVisible": true,
      "semantic": {
        "name": "Server chassis",
        "role": "enclosure",
        "description": "Illustrative enclosure for exploring cooling"
      },
      "provenance": {
        "origin": "generated",
        "factualSupport": "illustrative",
        "sourceRefs": []
      }
    }
  ],
  "relationships": []
}
```

Names are display text, never identity. Origin and factual support remain separate: an authored object is not automatically accurate, and generated geometry can be supported by references.

## 4. Geometry, coordinates and materials

`geometrySemanticsVersion: 1` fixes these conventions:

| Property | Exact meaning |
| --- | --- |
| Space | Right-handed; +Y up; asset front +Z; distances in metres |
| Transform | Local translation, quaternion `[x,y,z,w]`, positive scale; matrix composition `T × R × S` |
| Rotation | Unit quaternion; identity `[0,0,0,1]`; helper angles explicitly use radians |
| Origin | Geometry's documented local origin; parent transforms position it |
| Placement | Device-local root/anchor transform, separate from asset coordinates |
| Triangles | Indexed, counterclockwise when viewed from the outward-facing side |
| Color | Linear RGB with unpremultiplied alpha; values in `[0,1]` |
| Numeric conversion | Validate finite JSON numbers and bounds before conversion to native Float32 |

No arbitrary matrices, shear or negative scale in v0. Store rest poses when an assembly needs repeatable deconstruction; animation changes presentation toward absolute target transforms. It does not repeatedly add offsets to the last animated pose.

These choices follow glTF's metre, right-handed, +Y-up, XYZW and TRS conventions. glTF material factors use linear values. Its object names need not be unique, reinforcing the need for our own IDs. [glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html). RealityKit also uses metres and Y-up. [Apple USD asset guidance](https://developer.apple.com/documentation/usd/creating-usd-files-for-apple-devices).

Initial geometry recipes:

| Kind | Parameters and semantics |
| --- | --- |
| `box` | `size: [x,y,z]` gives full dimensions; centered at origin |
| `sphere` | Positive radius; centered at origin |
| `cylinder` | Positive radius and full height; centered along +Y |
| `cone` | Positive base radius and full height; base at `-height/2`, tip at `+height/2` |
| `tube` | Local-space polyline centerline and positive radius; compiler owns tessellation |
| `arrow` | Local-space start/end and bounded shaft/head dimensions |

Labels are separately addressable annotations with text, attachment target and a native layout policy. Do not turn every label into a bespoke mesh. Defer arbitrary Boolean solids, CAD surfaces, sweeps and extrusion until a demonstrated interaction requires their geometry-kernel behavior.

Start with opaque metallic/roughness materials and unlit annotations. Require alpha 1 for this initial material capability; transparency and x-ray rendering require separately negotiated behavior. An authoring helper may accept an sRGB hex color; normalization converts it to `baseColorLinear`. Do not interpret hex bytes as linear intensities. Native shading can vary between renderers even when parameters agree.

The Swift geometry compiler computes vertices, normals and indices. It uses Float32 position/normal buffers and UInt32 triangle indices in memory. MeshDescriptor exposes the native construction path. There is no custom binary mesh network format in v0. [Apple MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor).

Provisional admission ceilings are 256 KiB decoded JSON per message, 128 operations/created nodes per batch, 2,000 nodes per scene, and 256 centerline points per tube. Track unique mesh triangles and expanded visible-instance triangles separately, with a provisional ceiling of 500,000 for each. Sharing a mesh reduces resource storage but does not eliminate the rendering cost of its instances. These ceilings are not target scene complexity or evidence that a particular device sustains its frame rate.

The implementation must additionally set bounds for pending batches, prepared bytes, textures, materials, imported decoded resources, and total generation duration before admitting those capabilities. File byte size alone does not bound decoded mesh/texture memory. Reject invalid indices, zero-length segments, unsupported recipes and excessive expanded output before allocating native resources. Profile the actual target device and lower limits as needed.

## 5. Wire messages and bounded generation

Use one complete UTF-8 JSON object per WebSocket message. Do not interpret arbitrary token deltas as executable scene changes. A handshake declares protocol and capabilities; the server returns the selected supported subset before mutation messages are admitted.

```json
{
  "type": "hello",
  "protocolVersion": 1,
  "sceneSchemaVersions": [1],
  "geometrySemanticsVersions": [1],
  "capabilities": ["box.v1", "cylinder.v1", "tube.v1", "arrow.v1"]
}
```

Protocol version describes message behavior; schema version describes document structure; geometry semantics version describes recipe interpretation. Changing cylinder origin is a geometry compatibility change even if its JSON shape remains identical.

A `generation.begin` carries `sceneId`, `generationId`, `intentEpoch` and `initialBaseRevision`. Acceptance reserves a generation scope against that starting state. The first implementation sends one bounded complete model proposal as one generation batch; true progressive multi-batch streaming is planned, not implemented. When multiple batches are enabled, they carry monotonically increasing `sequence` values and do not each reuse a stale global base revision.

```json
{
  "type": "generation.batch",
  "protocolVersion": 1,
  "sceneId": "scene_live",
  "generationId": "generation_cooling",
  "intentEpoch": 4,
  "sequence": 1,
  "requestId": "request_batch_1",
  "operations": []
}
```

Batches can introduce generation-owned nodes and refer to earlier-sequence nodes or approved anchors. They may queue before predecessors commit, but final dependency validation and installation wait for those predecessors. No forward-sequence references are allowed. Buffer out-of-order messages only within negotiated count/byte limits; on a gap request the next expected sequence, then fail the scope if the configured deadline expires. Never skip a missing batch.

Compute `payloadHash` with the typed Astra Canonical Request v1 encoder implemented by `SpatialCore`; the wire remains JSON and RFC 8785 is not used. Retries reuse the exact request ID and payload bytes. Same-ID/same-hash retries return the previous receipt; same-ID/different-hash requests fail. Bind sequence identity to scene, generation and epoch; reusing the same sequence with different content also fails. A confirmed superseding intent invalidates the old generation scope. `generation.finish` supplies `lastSequence`; completion requires every batch through that sequence to be installed.

Edits to pre-existing scene nodes use a separate transaction with strict `baseRevision`; a generation scope is not permission to ignore conflicts elsewhere. Generation receipts report `accepted`, `completed`, or `rejected` for scope lifecycle. Scene receipts report `installed` or `rejected` for each committed batch/patch; `installed` means accepted semantic state was applied, not that the generation is complete:

```json
{
  "type": "scene.receipt",
  "protocolVersion": 1,
  "sceneId": "scene_live",
  "generationId": "generation_cooling",
  "requestId": "request_batch_1",
  "sequence": 1,
  "status": "installed",
  "revision": 18,
  "affectedNodeIds": ["node_airflow"]
}
```

These independent specimens show field shapes, not an executed request/receipt pair. `installed` means scene/native state committed; it does not prove a captured display frame or finished animation.

## 6. Artifact formats, hashes and checkpoints

Each immutable geometry definition receives a `contentHash` computed by application code. Hash the normalized recipe and geometry semantics version with the typed binary canonical encoder used by `SpatialCore`; the wire format remains JSON and no RFC 8785 serializer participates. Exclude IDs, display names, provenance and node placement. A compiled mesh cache key additionally includes compiler version and tessellation policy. Hash binary files over their exact bytes.

Large assets travel through bounded HTTP downloads using application-issued handles with format, byte length and SHA-256 metadata. Do not embed base64 meshes in conversational messages. Store USDZ/GLB bytes in artifact storage; database/checkpoint records contain references.

The current imported path uses an approved host descriptor and `GeometryRecipe.importedAsset` references. The loader asynchronously decodes and caches the bundled USDZ `Entity` hierarchy on Load rack, preserves PBR materials, and maps approved `partID`s to descendants. Model output cannot supply a URL, file path, or arbitrary asset. The faithful app catalog contains the Akeil rack/frame and 18 server parts, with SHA-256 `assetID` `sha256:b1ae63bb5e95a52152dba08574b0e6b852ec9499fb1e0cf63360e96e3f31bad1` and 13,232,052 bytes; it retains about 2.99 million expanded triangles and has validated source vertices, normals, materials, and the corrected PSU6 placement. The raw pinned URL and provenance remain in `source-catalog.json`. No automatic LOD or runtime selective-detail path exists. The raw interior is absent and remains only in a `.blend` source; there is no lazy interior loading path.

USDZ requires uncompressed, aligned packaging; ordinary ZIP repackaging is unsuitable. [USDZ specification](https://openusd.org/dev/spec_usdz.html). GLB export is a later interchange path. A Unity client must deliberately convert coordinate basis, including rotations and winding, and verify importer results. [Unity glTFast loading](https://docs.unity3d.com/Packages/com.unity.cloud.gltfast@6.19/manual/ImportRuntime.html).

A checkpoint records accepted normalized content, geometry/material definitions, provenance, artifact references and its originating revision. It excludes pending jobs and GPU resources. Reopening retains `documentId` and stable node IDs, creates a fresh `sceneId`, rebuilds resources and requests new physical placement. A saved semantic scene does not guarantee recovery of the previous AR anchor. The persistence implementation must state when this checkpoint becomes durable; a wire installation receipt alone does not establish durability.
