# Apple asset performance audit

2026-09-08. This audit follows the actual `Akeil` rack through native loading, resource sharing, selection, accepted scene state, and release. It supplements [the asset intake](imported-rack-review.md) and [the API reference study](realitykit-import-references.md). It distinguishes measurements on this Mac from unmeasured iPhone/iPad AR performance.

## Decision

Keep Blender/OpenUSD as the authoring and processing layer, immutable native asset files as the rendering payload, and the semantic scene document as Astra's edit surface. Keep `Entity(contentsOf:)` for an editable imported assembly. Its hierarchy-preserving behavior fits the eighteen independently selectable servers; flattening the whole rack would discard the boundaries the product needs. Apple's `Resource` model explicitly supports sharing expensive resources, and the supplied rack already realizes that sharing. [Entity loading](https://developer.apple.com/documentation/realitykit/loading-entities-from-a-file), [shared resources](https://developer.apple.com/documentation/realitykit/resource).

Do not translate the rack's millions of vertices into model-visible JSON or rebuild those vertices for a translation, hide, selection, or explanatory arrow. The accepted geometry reference identifies a package and part. Native mesh resources remain in the renderer. Procedural geometry is a peer, compiled only when its geometry identity changes. The current `GeometryCompiler` rejects imported recipes so they cannot accidentally enter the primitive-mesh compiler.

## Actual native sharing and process-memory probe

The standalone Swift probe uses public `ModelComponent`, `MeshResource.contents`, `ObjectIdentifier`, `Entity.clone(recursive:)`, and Darwin process-memory APIs. Hardware: Apple M5 Pro, 48 GiB RAM, macOS 26.5.2. It loads the pinned source and the conservative mobile derivative in separate processes. Those comparison processes overlapped; OS file-cache state and other machine activity were uncontrolled. These are directional measurements, not a controlled device benchmark.

| Measurement | Original source | Conservative derivative |
| --- | ---: | ---: |
| USDZ bytes | 25,786,225 | 10,549,419 |
| Native imported entities | 149 | 149 |
| Native ModelComponents | 55 | 55 |
| Unique MeshResource objects | 38 | 38 |
| Unique triangles | 791,123 | 233,060 |
| Triangles across visible occurrences | 2,989,750 | 1,107,642 |
| Native load | 2.926 s | 1.184 s |
| Recursive whole-rack clone | 0.482 ms | 0.431 ms |
| Process physical footprint before load | 5.69 MB | 5.70 MB |
| Process physical footprint immediately after load | 466.34 MB | 247.37 MB |
| Process resident-size peak | 538.54 MB | 266.52 MB |
| Physical footprint two seconds after releasing roots | 353.57 MB | 180.21 MB |

All eighteen server ModelComponents share **one identical MeshResource object**. Each server mesh has one model/instance, two parts, and two material slots. Recursively cloning the whole rack creates distinct entities while retaining all 55 corresponding mesh identities. The source has 76 mesh parts among unique resources and 110 across occurrences. Mesh parts/material slots are not measured GPU draw calls.

Both original and clone roots deallocated immediately after release, checked through weak references. The process did not return to baseline. RealityKit initialization, engine caches, allocator behavior, and deferred cleanup contribute to its footprint. The snapshots neither isolate GPU allocation nor measure the resident cost of only this asset. They demonstrate why package bytes cannot serve as a physical-memory budget. No ARView, scene insertion, frame rendering, network transfer, iPhone, or iPad was involved.

Reproducible local probe source and raw measurements are under ignored `runtime/asset-probes/resource-sharing.swift`, `source-resource-sharing-repeat.json`, and `mobile-resource-sharing.json`. Source SHA-256: `aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba`; conservative derivative: `685fb4717cd6209bbb7ecc9a9e993c4d124fa5860958ae0d650215e155a3d84b`. The derivative comparison measures reduced geometry; it does not certify visual fidelity.

### Faithful indexed-normal candidate

The subsequent faithful v2 package (`b1ae63bb5e95a52152dba08574b0e6b852ec9499fb1e0cf63360e96e3f31bad1`) is 13,232,052 bytes. Native comparison of all eighteen server roots and all 36 corresponding mesh parts found identical vertex positions, normals, triangle indices, material indices, and local transforms after RealityKit import. Maximum position and normal component delta was zero. Compared PBR slot values also matched, including color, metallic, roughness, emission, culling, blending, depth behavior, and texture presence. This directly verifies the indexed `primvars:normals` encoding on this Mac; it is stronger than only observing a successful file load.

V2 retains 149 entities, 55 models, 38 unique meshes, one shared server mesh, and all 2,989,750 triangles across occurrences. One native load took 2.358 seconds, with 443.37 MB immediate process physical footprint and 523.85 MB resident-size peak. Recursive cloning took 0.738 ms. This is primarily a distribution-size improvement; it does not reduce the runtime geometry. These measurements are not controlled enough to claim a reliable load-time or memory improvement over the original. The server comparison does not independently validate the two intentional PSU geometry corrections and does not inspect rendered pixels. Artifacts: `runtime/asset-probes/faithful-v2-resource-sharing.json`, `faithful-v2-native-server-comparison.json`, and `compare-server-meshes.swift`.

## Fixes made from the code audit

- **Selection resources:** the previous renderer eagerly created twelve outline ModelEntities for each of eighteen servers, even with no selection. The renderer now creates one outline on first selection, reparents it to the selected wrapper, and shares one cube MeshResource across its twelve scaled edges. Repeated selection of the same node returns immediately. Authored imported materials and the single bounding-box collider per server are preserved.
- **Resource lifetime:** the previous two-entry catalog rejected a third asset forever. The catalog now evicts the least recently used unpinned prototype when admission needs space. Accepted documents and all available undo checkpoints pin their imported definitions. A prepared replacement holds a separate staged reference until the controller either installs or rejects it.
- **Bounded replacement:** the normal cache target is two packages. A third may stage while an accepted scene and its undo remain intact. All cached and in-flight packages together must fit three entries, 128 MiB of approved file bytes, and two million unique source triangles. These are explicit admission costs, not promised CPU/GPU memory limits. A replacement that cannot fit fails before loading; history is not silently discarded.
- **Memory pressure:** iOS memory warnings purge only unused prototypes. Current, undo, and staged assets remain pinned. Releasing app-owned entities permits cleanup; immediate GPU reclamation is not assumed. [UIKit memory warning notification](https://developer.apple.com/documentation/uikit/uiapplication/didreceivememorywarningnotification).
- **Part resolution:** a single traversal builds an entity-name index before resolving the approved part bindings. The importer previously traversed the full hierarchy once per named part. Duplicate and overlapping bindings still fail explicitly.
- **Hand detection:** transient detector failures expire stale pointing and write diagnostics; they no longer overwrite conversation activity or present a global request error.

Implementation: `packages/SpatialKit/Sources/SpatialApple/Rendering/ImportedAsset.swift`, `SceneRenderer.swift`, `SceneController.swift`, and `SpatialCore/SceneState.swift`. The imported tests cover the shared outline, material preservation, repeated selection, aggregate admission, three real-package cycles, retention through a simulated memory purge, rejected replacement preserving old pins, and undo restoration.

## Best next native experiments

1. **Compile a faithful exterior at build time.** Apple recommends `.reality` over USDZ for loading performance. Reality Composer Pro compiles source assets to `.reality`, and Apple's Diorama sample describes improved loading. Compare the same validated semantic boundaries in a compiled binary before choosing it as the shipped form. Keep USDZ/OpenUSD as the portable interchange/provenance form. `Entity.write(to:)` is also public, but Apple warns that this asynchronous method may block the main thread during setup or the entire call. Use it on the Mac processing path, not during active AR. [CPU guidance](https://developer.apple.com/documentation/realitykit/reducing-cpu-utilization-in-your-realitykit-app), [Reality Composer Pro import](https://developer.apple.com/documentation/realitycomposerpro/realitycomposerpro-essentials-addingentitiestoscene), [Diorama](https://developer.apple.com/documentation/visionos/diorama/), [Entity export](https://developer.apple.com/documentation/realitykit/entity/write(to:)).
2. **Load details as separate files.** Export one useful assembly at a time: server interior, motherboard, then a selected component if necessary. Preserve the parent placement and stable part binding. Native preparation is asynchronous; installation remains one synchronous accepted-state transition. Keep one detail request active and reject late results using document/intent generation. This makes both cancellation and resource ownership inspectable.
3. **Evaluate native references only where their contract fits.** `ReferenceComponent` has documented bundle-based `.onDemand` load and explicit release. It is an option for a fixed bundled detail library. It does not accept arbitrary downloaded URLs through its public initializers. `Entity.ConfigurationCatalog` selects authored USD variant sets or `.reality` configurations, including representation/LOD choices; it is not documented automatic distance streaming. No public RealityKit load-mask interface for arbitrary USD payloads was found. Do not infer partial decoding from hidden subtrees in a single USDZ. [ReferenceComponent](https://developer.apple.com/documentation/realitykit/referencecomponent), [ConfigurationCatalog](https://developer.apple.com/documentation/realitykit/entity/configurationcatalog).
4. **Profile render submission before custom instancing.** The server mesh allocation is already shared. `MeshInstancesComponent` can reduce repeated draw submission, but independent per-server selection and manipulation then need an instance-index mapping or promotion to a separate entity. Introduce that complexity only if measured render-thread/draw costs justify it. Keep collision proxies independent of CAD complexity. [MeshInstancesComponent](https://developer.apple.com/documentation/realitykit/meshinstancescomponent), [WWDC25 RealityKit](https://developer.apple.com/videos/play/wwdc2025/287/).

## Remaining gaps and acceptance measurements

The file cache is digest-addressed but still has no explicit disk LRU quota. Concurrent requests for the same prototype are rejected rather than joined. The download path uses a complete-file download; byte-count validation occurs after download. These should be tightened before opening a broad user asset catalog. Do not label the current cache a persistent document store: the saved semantic checkpoint does not yet ensure durable custody or automatic reloading of all referenced binaries.

The current source asset has no image textures, so texture compression is not its present bottleneck. Future imported textures require a separate resident texture budget: image file size does not describe decoded/mipmapped storage. Small textures matched to their display size and material atlases are supported optimization techniques. [GPU guidance](https://developer.apple.com/documentation/realitykit/reducing-gpu-utilization-in-your-realitykit-app).

On **both physical devices**, measure download, digest verification, native decode, entity preparation, synchronous installation, first visibly rendered frame, steady/peak process memory, CPU main/render time, and GPU time. Use `ARView.DebugOptions.showStatistics` and Instruments/Metal captures. Awaiting `Entity(contentsOf:)` proves loading completed; it is not a receipt for a displayed frame. Test rapid switching, cancellation, a selected-server move, a generated procedural addition, and release/reload under a sustained AR session. Simulator and Mac preparation timings cannot establish mobile AR smoothness. [Performance measurement](https://developer.apple.com/documentation/realitykit/improving-the-performance-of-a-realitykit-app), [ARView statistics](https://developer.apple.com/documentation/realitykit/arview/debugoptions-swift.struct/showstatistics).
