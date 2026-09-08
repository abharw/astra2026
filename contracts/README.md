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

The model values are `SceneDocument`, `GeometryDefinition`, `Material`, `SceneNode`, `Relationship`, `Transform3D`, `Vec3`, and `Quaternion`. Geometry is a closed `GeometryRecipe` enum with `box`, `sphere`, `cylinder`, `cone`, `tube`, and `arrow`. Operations are a closed `SceneOperation` enum: `putGeometry`, `putMaterial`, `createNode`, `removeNode`, `setTransform`, `setGeometry`, `setMaterial`, `setVisibility`, `putRelationship`, and `removeRelationship`.

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

`payloadHash` is lowercase hex SHA-256 over **Astra Canonical Request v1**, using every request field except `payloadHash`. This binds scene, epoch, revision/scope, request identity, sequence, and operations. The canonical bytes start with UTF-8 `astra-request-v1` plus a zero byte. Values then use their documented field order: strings are a big-endian UInt32 byte count plus unnormalized UTF-8; arrays use a big-endian UInt32 count; unsigned integers use big-endian UInt64; signed integers use big-endian Int64; booleans use `00`/`01`; optionals use an absent/present byte; enums write their wire tag as a string; doubles use big-endian IEEE-754 binary64 with negative zero normalized to positive zero. Non-finite doubles are invalid before hashing. Composite values recursively use the field order in `scene.schema.json`'s `x-astra-hash-order` annotations. No JSON serializer participates in the hash. `SpatialCore.canonicalPayloadHash(for:)` is the reference implementation and fixtures include fixed vectors for other languages. Same request ID plus the same full request hash returns the original receipt; reuse with any different field is rejected. Reusing a generation sequence with different request content is also rejected.

Geometry `contentHash` uses the same value encoding with the UTF-8 header `astra-geometry-v1`, a zero byte, the geometry-semantics version as signed Int64, and the recipe in its annotated order. Geometry and material definitions are immutable by ID; edits create a definition and repoint selected nodes.

## Geometry semantics version 1

Distances are metres. Model space is right-handed, +Y up, +Z forward. Arrays encode vectors as `[x,y,z]` and quaternions as `[x,y,z,w]`; validators require a unit quaternion within `1e-6` and reject other rotations. Node transforms are local to their optional parent. Scale components must be finite and strictly positive. Geometry definitions are immutable: changing shape creates a new `geometryId`; node identity remains stable.

- `box`: positive `[width,height,depth]`, centered at the origin.
- `sphere`: positive `radius` and segments in the bounded range.
- `cylinder`: positive `radius` and `height`, centered on the Y axis.
- `cone`: non-negative radii with at least one positive, positive height, centered on Y.
- `tube`: 2–256 finite centerline points and positive radius.
- `arrow`: finite distinct `start`/`end`, positive shaft/head radii and positive head length no longer than the arrow.

Generic group nodes omit `geometryId`. A node may reference at most one parent. `relationships` are typed semantic edges independent of containment.

## V1 budgets and exclusions

Decoded messages are capped at 256 KiB by transport, batches at 128 operations and 128 newly created nodes, documents at 2,000 nodes, 2,000 geometry definitions, 512 materials, and tubes at 256 points. V1 has no arbitrary meshes, labels, textures, binary assets, CSG, sweeps, extrusion, forward generation references, concurrent generation scopes, or automatic rebasing. Unsupported capabilities are rejected explicitly.
