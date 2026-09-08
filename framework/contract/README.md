# Astra scene contract v1

This directory is the portable boundary between the backend and `SpatialCore`. JSON Schema 2020-12 is normative for wire structure. `SpatialCore` additionally enforces references, acyclic containment, finite numeric values, resource budgets, revision/epoch preconditions, generation ownership, ordering, and immutable retries.

## Swift consumer API

`SpatialCore` is Foundation-only. Its public concrete surface is:

```swift
public struct SceneState: Sendable, Equatable {
    public private(set) var sceneId: String
    public private(set) var revision: UInt64
    public private(set) var intentEpoch: UInt64
    public private(set) var document: SceneDocument
    public mutating func apply(_ message: ClientMessage) -> ApplyReceipt
    public mutating func advanceIntentEpoch() -> UInt64
    public mutating func undo(requestId: String) -> SceneReceipt
}

public enum ClientMessage: Codable, Sendable, Equatable {
    case hello(Hello)
    case generationBegin(GenerationBegin)
    case generationBatch(GenerationBatch)
    case generationFinish(GenerationFinish)
    case scenePatch(ScenePatch)
}
```

`apply` is synchronous and transactional. An installed request increments `revision`; rejection leaves the document unchanged. `ApplyReceipt.scene` carries an `installed`/`rejected` `SceneReceipt`; `ApplyReceipt.generation` carries an `accepted`/`completed`/`rejected` `GenerationReceipt`. A renderer may prepare native resources first, but must call the reducer again at its serialized installation boundary.

`hello` is decoded by `ClientMessage` so one closed decoder covers the portable envelopes, but transport negotiates it before calling `SceneState.apply`. Use `SceneWireDecoder` for untrusted JSON; direct `JSONDecoder` decoding is structural only and does not reject unknown properties. `SceneWireDecoder.decodeMessage`, `decodeDocument`, and `decodeReceipt` enforce the 256 KiB limit and closed keys before Codable decoding; document decoding also runs semantic validation.

The model values are `SceneDocument`, `GeometryDefinition`, `Material`, `SceneNode`, `Relationship`, `Transform3D`, `Vec3`, and `Quaternion`. Geometry is a closed `GeometryRecipe` enum with `box`, `sphere`, `cylinder`, `cone`, `tube`, `arrow`, `importedAsset`, and `flow`. Operations are a closed `SceneOperation` enum: `putGeometry`, `putMaterial`, `createNode`, `removeNode`, `setTransform`, `setGeometry`, `setMaterial`, `setVisibility`, `putRelationship`, and `removeRelationship`.

## Wire envelopes

Every object is closed. The top-level `type` tags are exactly:

- `hello`: protocol/schema/geometry versions and bounded capabilities.
- `generation.begin`: `requestId`, `sceneId`, `generationId`, `intentEpoch`, `initialBaseRevision`, `scopeParentNodeId`.
- `generation.batch`: immutable `requestId`, `sceneId`, `generationId`, `intentEpoch`, `sequence` (starting at 1), `payloadHash`, and `operations`.
- `generation.finish`: `requestId`, scope identity, epoch, and `lastSequence`.
- `scene.patch`: immutable `requestId`, `sceneId`, `intentEpoch`, strict `baseRevision`, `payloadHash`, and `operations`.
- `scene.receipt`: actual mutation result with `status` (`installed` or `rejected`), resulting `revision`, affected node IDs, and an optional closed rejection.
- `generation.receipt`: scope admission/completion result with `status` (`accepted`, `completed`, or `rejected`) and the committed cursor. Admission and completion do not claim geometry installation.

A generation owns only nodes and definitions created through its scope. Its batches may create beneath `scopeParentNodeId`, refer to approved pre-existing parent anchors, and refer backward to previously committed batches. They cannot mutate or remove pre-existing content. V1 holds one active generation scope; a patch, undo, epoch advance, or competing begin revokes it.

`payloadHash` is lowercase hex SHA-256 over **Astra Canonical Request v1**, using every request field except `payloadHash`. This binds scene, epoch, revision/scope, request identity, sequence, and operations. The canonical bytes start with UTF-8 `astra-request-v1` plus a zero byte. Values then use their documented field order: strings are a big-endian UInt32 byte count plus unnormalized UTF-8; arrays use a big-endian UInt32 count; unsigned integers use big-endian UInt64; signed integers use big-endian Int64; booleans use `00`/`01`; optionals use an absent/present byte; enums write their wire tag as a string; doubles use big-endian IEEE-754 binary64 with negative zero normalized to positive zero. Non-finite doubles are invalid before hashing. Composite values recursively use the field order defined by this contract. No JSON serializer participates in the hash. `SpatialCore.canonicalPayloadHash(for:)` is the reference implementation and fixtures include fixed vectors for other languages. Same request ID plus the same full request hash returns the original receipt; reuse with any different field is rejected. Reusing a generation sequence with different request content is also rejected.

Geometry `contentHash` uses the same value encoding with the UTF-8 header `astra-geometry-v1`, a zero byte, the geometry-semantics version as signed Int64, and the recipe in its annotated order. Geometry and material definitions are immutable by ID; edits create a definition and repoint selected nodes.

The `flow` recipe's canonical order is the string `flow`; `source.nodeId` as a string and `source.localPoint` as three doubles; `target.nodeId` as a string and `target.localPoint` as three doubles; the `routePoints` UInt32 count followed by three doubles per point; `direction` as a string; `width` as a double; `label` as a string; and `animated` as one boolean byte. Vectors have no array count in canonical bytes. Adding this recipe does not change any existing recipe encoding or v1 hash vector.

## Geometry semantics version 1

Distances are metres. Model space is right-handed, +Y up, +Z forward. Arrays encode vectors as `[x,y,z]` and quaternions as `[x,y,z,w]`; validators require a unit quaternion within `1e-6` and reject other rotations. Node transforms are local to their optional parent. Scale components must be finite and strictly positive. Geometry definitions are immutable: changing shape creates a new `geometryId`; node identity remains stable.

- `box`: positive `[width,height,depth]`, centered at the origin.
- `sphere`: positive `radius` and segments in the bounded range.
- `cylinder`: positive `radius` and `height`, centered on the Y axis.
- `cone`: non-negative radii with at least one positive, positive height, centered on Y.
- `tube`: 2–256 finite centerline points and positive radius.
- `arrow`: finite distinct `start`/`end`, positive shaft/head radii and positive head length no longer than the arrow.
- `importedAsset`: approved `assetID` plus `partID`; the asset must be present in the native descriptor catalog.
- `flow`: structural `source` and `target` attachments, each a closed `{nodeId, localPoint}` object; zero to eight finite `routePoints`; `direction` (`forward` or `reverse`); `width` from 0.001 through 0.25 metres; `label` of at most 80 UTF-8 bytes (empty allowed); and required boolean `animated`. JSON Schema's `maxLength: 80` counts characters; semantic validation additionally enforces the UTF-8 byte limit. The recipe requires the negotiated `flow.v1` capability.

Generic group nodes omit `geometryId`. A node may reference at most one parent. `relationships` are typed semantic edges independent of containment.

## Flow binding and lifecycle

A flow is geometry on an ordinary `SceneNode`, with that node's stable identity, parent, visibility, material, and provenance. Attachments identify exact structural nodes and points in their respective local spaces. Route points and width are local to the flow node. The renderer resolves each endpoint from the complete candidate transform hierarchy as `inverse(flowWorld) * endpointWorld * localPoint`; changing an endpoint or an ancestor transform therefore updates the path. `forward` travels from source to target through the route points; `reverse` travels along the same path in the opposite direction. This illustrates a relationship and does not assert a physical simulation.

Validation applies attachment references to every node instance that uses a flow recipe, including shared recipes. Endpoints must exist and must not themselves use flow geometry or sit beneath another flow node. A flow cannot bind to itself or any of its descendants. Both attachments may refer to the same structural node when their local points differ. Unused definitions still require a valid recipe but do not require live attachment references. At most 32 flow node instances may exist in a document, including hidden instances.

Editing a flow creates a new immutable geometry definition and uses `set.geometry` on the existing node. Hiding uses `set.visibility`; deleting uses `remove.node`; ordinary Undo restores the prior document. Removing a bound structural node must remove its dependent flow instances in the same transaction, otherwise validation rejects the transaction atomically. Moving distinct attachments to coincident transformed positions retains the node and suppresses degenerate path, arrowhead, and marker meshes instead of rejecting the scene change.

Native rendering uses a smooth path bounded to 128 samples, eight radial segments, and at most four moving markers per flow. The renderer owns tessellation, arrowhead proportions, and marker speed. Its unlit material uses the ordinary scene material color. The renderer caches path resources, arc lengths, and labels; frame updates change only marker transforms. Disabling animation, including Reduce Motion, leaves the static path and label visible. These renderer details are not additional document state.

## Measured bounds in phone snapshots

`NodeLocalBounds` is snapshot context, outside `SceneDocument`, geometry recipes, and canonical document/request hashes. Each record has `nodeId`, `minimum: [x,y,z]`, and `maximum: [x,y,z]` in the named structural node's local coordinate space. A phone snapshot supplies at most 128 records and stamps them with that snapshot's scene identity, revision, and intent epoch. Records must refer to nodes in that snapshot, have finite values, and have ordered minimum/maximum extents. Native measurement includes hidden structural geometry and transformed structural descendants of assemblies, excludes flow geometry and renderer helpers, and omits empty or non-finite bounds. The backend may use these measured records for attachment placement; it must not present invented bounds as native measurements.

## V1 budgets and exclusions

Decoded messages are capped at 256 KiB by transport, batches at 128 operations and 128 newly created nodes, documents at 2,000 nodes, 2,000 geometry definitions, 512 materials, and tubes at 256 points. Flows are limited to 32 node instances, eight route points each, and labels of 80 UTF-8 bytes. V1 has no arbitrary meshes, standalone labels, textures, CSG, sweeps, extrusion, forward generation references, concurrent generation scopes, or automatic rebasing. Imported USDZ is a native rendering asset referenced only through approved `assetID`/`partID` descriptors; it is not model-provided executable content. Unsupported capabilities are rejected explicitly.
