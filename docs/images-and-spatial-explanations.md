# Images 2.5 and spatial explanation quality

September 8, 2026. Research and proposed integration; Images 2.5 has not been called or integrated in this app.

Arav's subsequent implementation order is repository reorganization → image API integration → richer native geometry. The [image integration record](images-2.5-integration-status.md) and [native flow record](native-flow-integration.md) describe the implementation; the comparison below explains their separate roles.

## What the current session proves

Arav reported pulling out one server, asking about heat flow and requesting arrows. The matching physical-iPhone session contains three successful native installations and three completed typed Realtime responses. Node counts progress 20 → 20 → 29 → 33, with scene revisions 0 → 1 → 2 → 3. The last turn took 18.984 seconds from native text submission to final response, and 15.460 seconds from backend admission to receipt-gated explanation. [Redacted session evidence](evidence/iphone-heat-flow-session.json).

Those logs confirm execution and continuity. They do not retain raw prompts, mesh recipes or rendered frames. The mapping of individual requests to “pull out,” “explain” and “arrows” follows Arav's description and their sequence; it is not reconstructed from logged message text.

## The model's current visual vocabulary

The [authoring tool](../backend/src/astra/authoring-tool.ts) exposes a straight shaft/cone arrow and a static polyline tube, with solid opaque colors, roughness and metallic properties. It has no label, gradient, animation, smooth flow-arrow, generated texture or source/target attachment operation. The [native material compiler](../framework/Sources/SpatialApple/Rendering/MaterialCompiler.swift) uses physically based shading, so annotation colors respond to scene lighting.

Astra can reason about the assembly but cannot request visual capabilities that the contract does not expose. Adding more mesh segments alone would not supply meaningful flow motion, readable labels or endpoints that follow moved components. Current imported-asset context also lacks explicit measured bounds and attachment points; including bounded host-derived geometry context would reduce spatial guesswork.

## Verified image-model capabilities

The exact models are `gpt-image-2.5-flare` and `gpt-image-2.5-sunburst`, with September 8 snapshots. They accept text/image inputs and produce raster images. Flare is the first model to evaluate for latency-sensitive illustrations; Sunburst is intended for more precise work with longer generation. [Flare model](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare), [Sunburst model](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst).

The API supports image generation/editing, PNG/JPEG/WebP, transparent PNG/WebP and optional streamed partial images. Reference images and masks can guide edits, but do not establish geometric constraints or independently editable components. The launch's 50% latency reduction is relative to the earlier image model; it is not a promised absolute generation time. The image guide notes that complex requests can take up to two minutes. No account-access, cost or latency experiment was run here. [Launch](https://openai.com/index/introducing-chatgpt-images-2-5/), [Image generation guide](https://developers.openai.com/api/docs/guides/image-generation).

## Recommended rendering responsibilities

| Need | Best first implementation |
| --- | --- |
| Show direction between real editable parts | Native node-bound curved path and arrowhead |
| Make motion obvious | A bounded pool of moving markers along the cached path |
| Keep color readable over camera imagery | Dedicated unlit annotation style, retaining scene occlusion |
| Explain with readable, factual labels | Native text projected from spatial anchors |
| Show a polished cross-section or concept diagram | Optional generated image panel beside the assembly |
| Move or deconstruct individual server parts | Existing semantic scene graph and imported geometry |

The first useful extension is a generic flow annotation. Astra chooses source/target node IDs, optional local attachment points, route points, direction, color and label. The renderer chooses smooth sampling, consistent proportions and marker motion. A flow remains a scene value with a stable identity and the same validation, revision, receipt and Undo semantics as other content. No rack-specific command handling is needed.

RealityKit's [UnlitMaterial](https://developer.apple.com/documentation/realitykit/unlitmaterial) supports predictable annotation color. [SceneEvents.Update](https://developer.apple.com/documentation/realitykit/sceneevents/update) can advance bounded marker transforms along a precomputed arc-length table. Apple demonstrates [spatially anchored screen annotations](https://developer.apple.com/documentation/arkit/creating-screen-annotations-for-objects-in-an-ar-experience). These do not require model calls or mesh rebuilding per frame. [LowLevelMesh](https://developer.apple.com/documentation/realitykit/lowlevelmesh) is unnecessary for a static path with moving markers unless profiling establishes a reason to use it.

## Where image generation would connect

Use a separate optional illustration job in the existing backend, initially through the direct Image API. The current Astra path enforces exactly one completed `propose_scene` function; adding a second tool to that same request would conflict with its admission rules. Responses supports image-generation tooling, but adopting it requires an explicit change to that contract. [Image generation tool](https://developers.openai.com/api/docs/guides/image-generation), [Astra supported tools](https://developers.openai.com/api/docs/models/gpt-6-astra).

1. Astra produces an illustration brief from the selected components, factual explanation and accepted scene revision. A cropped virtual-assembly snapshot can be optional reference input.
2. The backend generates the image and stores immutable bytes, returning a checksum, MIME type, dimensions, provenance and source revision. Keep image bytes outside ordinary scene/model snapshots.
3. The app displays a companion explanation panel with an explicit generating state. Late or cancelled jobs cannot attach to a superseded scene. Start with an app panel before adding image resources to the portable scene protocol.
4. If spatial panels prove useful, approve/cache the image like other resources and apply it to an unlit plane. A panel's pose can be edited; its individual pixels are not separate 3D components. [TextureResource](https://developer.apple.com/documentation/realitykit/textureresource).

For this heat-flow example, a generated cutaway could show why heat moves through a heatsink while native animated paths show where it travels in the actual assembly. Keep image generation outside the immediate spatial-response path.

## Evaluation before product integration

Compare Flare medium and high at a fixed resolution using the same component reference and brief. Measure direction correctness, component identity, label correctness, first-preview/final latency and bytes downloaded. Compare against native flow annotations while walking around and moving the selected part. Treat any generated heat visualization as a teaching illustration, not measured temperature or a computational fluid dynamics result. Test Sunburst only if a specific quality failure justifies its additional latency.

For native flows, use the same generic feature on a rack, lamp and simple three-node scene. Verify transformed endpoint attachment, finite geometry on reversing/near-parallel paths, Undo, Reduce Motion behavior and bounded frame cost on the physical devices.
