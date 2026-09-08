# RealityKit imported assets: API and performance references

Checked 2026-09-08 against current Apple documentation and the installed Xcode 26.6 (17F113), iPhoneOS 26.5 SDK. This is a design/reference note. It does not establish that the complete detailed Blender scene performs acceptably on iPhone 15 Pro or iPad Air M4. No device measurements were performed for this note.

## Recommended first import

Load the existing exterior USDZ as one imported assembly, preserving its internal hierarchy with `try await Entity(contentsOf: fileURL)`. Put it under an application-owned entity whose identity, transform, visibility, and selection belong to the accepted scene document. Keep procedural geometry as a peer in that document. Load a separately exported detail package only when the person opens that assembly or requests its detail.

The existing exterior package can validate native rendering, placement, selection, coexistence with procedural geometry, and persistence of its source identity. It cannot prove that the separate `.blend` detail collections already exist as usable runtime packages. Blender authoring files must be converted before the native app can load them. Processing/conversion tool choices are researched separately.

Apple documents that `Entity` loading preserves a hierarchy, while the model-specific loading methods flatten it. Flattening sacrifices access to the constituent parts. Prefer `Entity` for assemblies; reserve deliberate merging for decoration that will not need independent edits. [Loading entities from a file](https://developer.apple.com/documentation/realitykit/loading-entities-from-a-file).

## Verified API availability

The following signatures are present in the installed public `RealityFoundation.swiftinterface`, exported through `RealityKit`:

| API | iOS availability | Use here |
| --- | --- | --- |
| `Entity(contentsOf:withName:) async throws` | 18.0 | Load a local USD/USDZ or Reality file while retaining its hierarchy. |
| `Entity(named:in:) async throws` | 18.0 | Load bundled content. |
| `Entity(from: Data, named:) async throws` | 26.0 | In-memory input exists, but retaining a download buffer is unnecessary for large files already on disk. |
| `Entity.clone(recursive:)` | 13.0 | Create a placement from a cached prototype. |
| `ReferenceComponent` | 18.0 | Bundle-oriented references, with immediate or on-demand loading. |
| `ReferenceComponent.loadReference(at:) async throws` / `releaseReference(at:)` | 18.0 | Load/release an authored reference. |
| `LowLevelInstanceData` / `MeshInstancesComponent` | 26.0 | Render repetitions of a model using instance transforms. |
| `ShapeResource.generateBox(size:)` | 13.0 | Cheap selection/collision proxy. |
| `Entity.generateCollisionShapes(recursive:)` | 13.0 | Avoid calling recursively on a complex imported hierarchy. |

The entity initializers and cloning are main-actor isolated. Await the asynchronous initializer from the main actor; do not move entity graph mutation to a detached task merely because it loads a file. Modern async initializers replace the older Combine `LoadRequest` APIs, which the installed SDK marks deprecated in iOS 18.

Installed declaration locations, relative to `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk/System/Library/Frameworks/RealityFoundation.framework/Modules/RealityFoundation.swiftmodule/arm64e-apple-ios.swiftinterface`: entity initializers at lines 12028–12035; clone at 10563–10568; instancing at 11144–11170; reference loading at 13532–13575; collision generation at 8641–8650; shape generation at 12271–12278. These are declaration checks, not runtime acceptance results.

Apple’s initializer accepts a **file URL**. Download remote packages separately, verify their identity, and retain them locally before loading. `withName` names the resource for synchronization; it is not a USD prim selector or a replacement for the app’s node ID. [URL initializer](https://developer.apple.com/documentation/realitykit/entity/init(contentsof:withname:)).

`ReferenceComponent` is a valid native option, but its documented workflow references assets in bundles and saves a reference graph into `.reality`. Its constructors do not accept an arbitrary downloaded file URL. For user-imported and remotely built asset packages, a manifest plus explicit `Entity(contentsOf:)` loading provides the application’s required version, custody, and installation controls without adopting a second scene authority. Reconsider native references for a curated bundled scene. [ReferenceComponent](https://developer.apple.com/documentation/realitykit/referencecomponent).

## Stable identity and editable parts

Retain imported binaries as source artifacts. Scene JSON stores references and user edits, not a reconstruction of imported triangle arrays. A useful sidecar manifest records:

- Stable `assetID`, immutable content digest, media type, byte count, and retained relative file location.
- Exporter/tool version and source authoring digest for provenance.
- Units, up-axis, authored root transform, and canonical bounds.
- Stable semantic part keys, their source USD prim paths, and a validated way to locate corresponding runtime entities.
- Optional independently exported detail variants, their digests, bounds, and the semantic part they replace or refine.

Bind a stable scene node ID to an asset version and, when necessary, a part key. Keep the app’s wrapper transform separate from the imported authored transform. Convert units once at the asset boundary. Choose placement scale from stable manifest bounds; a detail load must not recenter or rescale the existing anchored assembly.

Do not assume that `Entity.name` is globally unique, that a Blender object name remains unchanged after every export, or that RealityKit exposes a durable source USD prim path. This SDK exposes name lookup and child traversal, not a public `usdPrimPath` property. Retain USD prim paths as source provenance and validate the runtime path/name mapping against the actual exported package. Prefer unique exported semantic names or explicit child-path segments over a global first-match name search. Duplicate/ambiguous or missing mappings are import errors rather than permission to edit the wrong part.

Map a hit entity upward to the nearest application-owned semantic wrapper. This fits the renderer’s existing `astra.node.<nodeID>` ancestry lookup. An imported root alone permits whole-assembly edits; claiming arbitrary internal-part editing requires the part mapping, selection proxies, and persisted overrides to be implemented as well. Do not rename every imported descendant to one wrapper ID.

Make material overrides explicit. Preserve authored materials by default; selecting a part should not permanently replace the whole asset’s material assignments. Independent entity copies and component value changes also do not imply that mutating a shared mesh/texture resource is isolated.

## Async loading, cancellation, and memory ownership

Use a small application-owned load queue and a bounded prototype cache keyed by immutable content identity and import policy. Coalesce requests for the same package. Clone a prototype for each placement instead of parsing the same source repeatedly; budget both prototypes and all live clones. Cloning copies component data and optionally children; it is not a promise that thousands of entities cost nothing or automatically become one GPU draw call. [Cloning entities](https://developer.apple.com/documentation/realitykit/entity/clone(recursive:)).

The loader should prepare an unattached hierarchy, validate its mapping and bounds, then recheck the current document/intent generation, target node, and expected asset digest immediately before installing it. Cancelling a Swift task is useful, but the reviewed Apple loading docs do not promise immediate interruption of every native decoding or GPU preparation stage. A superseded request must be unable to attach its result even if the load completes later.

Hidden content can remain resident. To release a detail level, detach its live entities and remove the application’s strong references to those entities, prototypes, pending task results, and disposable derived resources. Keep the original binary if required for reopening the saved document. Do not equate `isEnabled = false`, removal from the scene, or a cancelled waiter with guaranteed immediate GPU-memory reclamation. Measure the resulting footprint.

For an initial implementation, prefer one detail request at a time and a small cache over preloading every collection. Those are conservative application defaults, not Apple device limits. A later policy can use measured load latency, bounds, visibility, and memory pressure.

## Selection proxy example

This API sketch preserves the loaded hierarchy and adds a bounding-box proxy to a separate wrapper. It passed `swiftc -typecheck -swift-version 6 -target arm64-apple-ios26.0` against the installed iPhoneOS 26.5 SDK. The caller must still perform asset validation, stale-request checks, and accepted-scene installation. It selects the assembly, not every internal mesh; typechecking is not a runtime import or interaction test.

```swift
import RealityKit
import Foundation

@MainActor
func prepareImportedAssembly(from fileURL: URL, nodeID: String) async throws -> Entity {
    let imported = try await Entity(contentsOf: fileURL)
    try Task.checkCancellation()

    let wrapper = Entity()
    wrapper.name = "astra.node." + nodeID
    wrapper.addChild(imported)

    let bounds = imported.visualBounds(relativeTo: wrapper)
    let minimumSize = SIMD3<Float>(repeating: 0.001)
    let size = SIMD3<Float>(
        max(bounds.extents.x, minimumSize.x),
        max(bounds.extents.y, minimumSize.y),
        max(bounds.extents.z, minimumSize.z)
    )
    let proxy = ShapeResource.generateBox(size: size)
        .offsetBy(translation: bounds.center)
    wrapper.components.set(CollisionComponent(shapes: [proxy]))
    return wrapper
}
```

Use validated manifest bounds when possible, especially for animated/skinned content or when a full recursive bounds query is itself expensive. Only the intended selection entities need collision components. Overlapping coarse boxes can select empty space or occlude a deeper target; finer authored proxies are the next step when actual interaction demands them. If the imported file already contains collision components, normalize those deliberately according to the interaction policy.

`generateCollisionShapes(recursive: true)` traverses descendants and generates mesh-derived shapes. A root with no mesh does not gain a shape from `recursive: false`. Explicit boxes, capsules, or authored low-resolution proxy meshes avoid making every bolt part of the physics workload. [Collision generation](https://developer.apple.com/documentation/realitykit/entity/generatecollisionshapes(recursive:)).

## Performance choices that preserve the product contract

Apple recommends asynchronous loading, sharing mesh resources, breaking large assets into smaller packages, and limiting per-frame entity/system work. Mesh/material count matters as well as triangle count; merging can reduce submission work but oversized merged objects lose useful culling granularity. Merge decoration by material within an assembly, while preserving genuinely editable subassemblies. [Reducing CPU utilization](https://developer.apple.com/documentation/realitykit/reducing-cpu-utilization-in-your-realitykit-app).

Use `MeshInstancesComponent` for repeated decoration whose transforms can live in an instance buffer. It draws multiple instances from one entity and reduces repeated geometry/material submission. Individual instances are not independent semantic entities automatically: picking and editing need an instance-index mapping, or promotion of a selected instance to a separately editable entity. This is an optimization to introduce after identifying repeated meshes, not a reason to flatten every semantic part. [Instancing API](https://developer.apple.com/documentation/realitykit/meshinstancescomponent), [WWDC25 RealityKit session](https://developer.apple.com/videos/play/wwdc2025/287/).

Texture resolution must match on-screen demand. Apple recommends small textures, atlases, and varying resolution rather than uniformly large textures, and documents automatic mipmap use. Its iPhone/iPad guidance uses approximately 2048 pixels per side as a general content-authoring guideline, not a hard device limit. An uncompressed 2048×2048 RGBA8 base image alone is 16 MiB; all mip levels add roughly one third before implementation-specific compression and allocation overhead. USDZ file size is therefore not a resident-memory budget. [Reducing GPU utilization](https://developer.apple.com/documentation/realitykit/reducing-gpu-utilization-in-your-realitykit-app).

Use a coarse exterior, assembly detail, and selected-part detail as separate load units. An authoring collection is useful only if it exports to a meaningful package with stable identity, materials, and bounds. Hiding a subtree inside one already loaded enormous USDZ does not establish incremental decoding or memory release. The application should own explicit load/swap/unload behavior; no general-purpose automatic LOD component was found in the inspected iOS interface.

No public general entity/ARView GPU-prewarm method was found in the inspected SDK interfaces. `RenderCallbacks.prepareWithDevice` prepares custom render effects; it is not an imported-asset preparation API. Async file completion should be described as loaded/prepared, not as proof of a displayed frame. Apple supports preloading before interaction and awaiting related loads before scene insertion; measure the first visible frame and any insertion hitch separately. [Async bundle loading](https://developer.apple.com/documentation/realitykit/entity/init(named:in:)).

## Acceptance evidence still required

Run on both named physical devices, with the same package digest and configuration. Record cold/warm load time, first visibly rendered frame, scene-insertion hitch, steady and peak resident memory, render/main-thread time, meshes, draw calls, and submitted triangles. Include a sustained AR session, a selected-part edit, rapid detail switching/cancellation, unloading/reloading, and save/reopen with the source package available.

`ARView.debugOptions.insert(.showStatistics)` exposes frame, CPU, mesh, draw-call, and memory information for this ARView-based renderer. Use Instruments/Metal captures where the overlay cannot isolate a bottleneck. The iPad result cannot substitute for the iPhone result, and simulator success does not establish device GPU performance. [ARView statistics](https://developer.apple.com/documentation/realitykit/arview/debugoptions-swift.struct/showstatistics), [Performance measurement](https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app).

The first falsifier is straightforward: if the exterior alone cannot load and render smoothly within the chosen memory envelope on iPhone, reduce/export it before admitting more detail. Passing that check permits testing one detail assembly; it does not accept all 6,663 authored objects as a simultaneous runtime scene.
