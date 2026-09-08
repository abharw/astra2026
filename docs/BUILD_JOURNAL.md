# Development journal

All stages below were completed or investigated on September 8, 2026. This journal reconstructs the actual session in order. Repository commits were created afterward and group the existing source for review; they do not recreate a historical commit timeline.

## 1. Establish the interaction with a browser speaker model

**Goal:** take a speaker seen in a photo and explore a holographic assembly.

We authored five Three.js component groups: grille, cabinet, illustrative drivers, hanging bracket and wall mount. Orbit controls, selectable parts, an explosion slider, automatic orbit and hologram/material modes made the interaction concrete. Observed exterior features were distinguished from inferred interior geometry.

The result was deployed as the browser prototype. A runtime issue appeared because React effect callbacks returned the numeric result of an imperative update. These callbacks were changed to return nothing, then the live controls were checked again.

**What this established:** the interaction vocabulary. It did not provide camera tracking, automatic geometry reconstruction or room persistence. The speaker was an authored example, not a general object pipeline.

## 2. Move from the browser to the connected iPhone

**Goal:** point at arbitrary objects on the real phone, ask for reconstruction, and manipulate the result in AR.

We chose SwiftUI for controls, RealityKit for model rendering and interaction, and ARKit world tracking for camera pose and placement. The connected physical iPhone supported LiDAR and ran iOS 26.6.1. XcodeGen made the project configuration reproducible.

A separate Mac bridge holds the OpenAI API key. The iPhone holds a scoped bridge pairing credential and communicates over an authenticated WebSocket through an HTTPS tunnel. The key supplied during development was kept out of source and the app bundle; neither key nor pairing credential is in this repository.

**Evidence:** the app built, installed and launched on the physical phone. Live tracking readiness and the bridge connection were observed during the initial device check.

## 3. Build the actual image-to-component pipeline

The phone captures a real JPEG from the current AR frame, the selected target point, camera pose, viewport transform and a distance estimate. The bridge sends the image itself to `gpt-6-astra` through the Responses API.

The model returns a strict structured assembly: image bounds, estimated dimensions, confidence, component descriptions, evidence labels and bounded primitives. Both bridge and native code validate geometry before rendering. The model does not return executable rendering code.

RealityKit creates boxes, spheres, cylinders, cones and tori from that description. Components are grouped so they can animate independently while belonging to one assembly. This trades geometric fidelity for an inspectable, editable representation.

**Evidence:** a source-photo probe returned eight parts in about 45 seconds. Later actual phone captures produced laptop assemblies in about 56 and 67 seconds, and a six-part wall-mounted speaker in about 32 seconds. These are observed individual runs, not a latency benchmark. Generation is not instantaneous or frame-by-frame reconstruction.

**Limits:** one-view dimensions, rear geometry and hidden components remain estimates. A semantic component list is not an accurate scan or engineering CAD model.

## 4. Add voice tools

The bridge connects to `gpt-realtime-2.1`. The native app streams microphone PCM while voice is enabled and plays returned audio. Realtime invokes tools to request a fresh phone capture or to manipulate an existing assembly. Native command results are returned to the voice session so a spoken success is based on an actual command result.

Commands include explode, assemble, extract, return, move, rotate, scale, select a part, and toggle inferred geometry or rendering style. Movement is constrained while attached: a model must be pulled out before moving, rotating or scaling it.

**Evidence:** a real Realtime probe produced an explode tool call and audio. That is API/tool-path evidence; it does not establish every spoken phrase and every phone audio-route condition.

## 5. Correct the default placement behavior

**User correction:** the generated model should initially overlay its source, remain anchored there, and take apart/reassemble at that same location when tapped.

We added frozen LiDAR depth samples from the selected AR frame, local depth-normal estimation, and raycast/camera-facing fallbacks. The selected image bounds are projected onto an estimated surface plane to estimate extent and scale. The generated model is positioned relative to this source pose.

The renderer saves a home transform. Tap toggles component-local explosion offsets. Translation, rotation and scale gestures remain disabled until **Pull out**; **Return** restores the home transform and assembled state.

**Evidence:** the updated physical build installed successfully. The position logic was implemented, but precise visual fit was not independently demonstrated. The later persistence test checks preservation of the chosen transform, not whether that chosen transform is perfectly aligned to the real speaker.

## 6. Separate room tracking from object tracking

The user asked for Vision Pro-like awareness. We checked Apple's documentation and the implementation rather than describing a world anchor as object recognition.

The code tracks a coordinate in the room. It does not continuously track the physical object's identity or pose after someone picks it up. Apple's reference-object tracking uses a prepared 3D model trained in Create ML; the documented iPhone support requires iOS 27, while the connected phone was on 26.6.1.

A short multiview scan, object isolation and geometric fitting were identified as next steps for better stationary-object alignment. These were discussed, not implemented. Upgrading the OS alone would not create reference models for arbitrary objects.

References: [Apple object tracking](https://developer.apple.com/documentation/visionos/implementing-object-tracking-in-your-app), [iPhone reference-object integration](https://developer.apple.com/documentation/visionos/using-a-reference-object-with-arkit-in-ios).

## 7. Add persistent places and multiple objects

**User correction:** closing the app should not erase objects; returning to a place should bring them back.

We added a local saved-place library. Each file atomically stores an archived `ARWorldMap` and all generated objects: full assembly, ID, home/current transforms, explosion amount, rendering style, inferred-part visibility and extraction state.

The app requests a map about every five seconds when tracking is normal and world mapping is mapped or extending. It displays whether a usable map has been saved. Backgrounding also persists current object state against the cached map. An epoch identifier prevents an asynchronous map callback from an older session writing into a newly selected place.

Starting another reconstruction preserves the previous object in the scene. Tapping a previously placed model selects it as the active model for controls.

On a fresh launch or foreground return with a saved map, the app tries saved places in recency order, with a fifteen-second attempt per candidate. Models are restored only after ARKit has reported relocalizing followed by normal tracking. If none match, a new place starts without overwriting old place files. **Your places** supports an explicit retry or immediate new place.

This is local visual relocalization. A continuous walk remains one AR session/map; automatic geographical room boundaries and universal place recognition are not implemented.

References: [Apple saving/loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data), [initialWorldMap](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap).

## 8. Verify persistence on the actual phone

Four XCTest tests passed: independent saved-place updates with full object state, transform validation, invalid-map rejection and an empty library. Eight bridge validation tests had also passed.

The physical build stalled during an Xcode compiler query. Sampling the compiler showed it blocked writing diagnostic output. For that local build, a temporary compiler wrapper omitted verbose output only for the macro-introspection query; normal compilation still used Apple's compiler. The physical build then succeeded. This workaround is not part of application runtime behavior.

After installation, the user generated a six-part speaker. We observed a saved room file on the phone, then terminated and relaunched the app. The same saved room was restored and autosaved again. A before/after comparison confirmed:

- Same room and object IDs.
- Identical generated assembly geometry.
- Same assembled/exploded state.
- Maximum home/current matrix-element difference approximately 0.0000007.

The sanitized comparison is in [persistence-verification.json](../spatial-assembly/persistence-verification.json). Raw room files and images are excluded because they contain private spatial data.

The Mac phone preview turned black during this phase. Device launch, API activity and saved-file comparison were available, but independent visual alignment verification was not. This test reopened the app in the same location; it did not test leaving, entering another room, and returning later.

## 9. Publish an inspectable development record

The requested empty GitHub repository was initialized with the README-only `first commit` on `main`. The `Akeil` branch imports native source, the original browser source snapshot, configuration helpers, tests, architectural comments and this journal. Credentials, source photos, room maps, build products and hosting metadata were excluded.

## Continuing this journal

For each future change, append a dated entry with: the concrete user-visible problem, the implementation and rationale, tests or device evidence, and any remaining uncertainty. Keep proposals clearly separate from implemented behavior. Do not equate a successful build, generated API output, or matching saved matrices with a visually correct AR experience.
