# Next work: organization, generated visuals, richer geometry

Updated September 8, 2026. Implementation baseline: `103f798` on branch **`Arav`**. Arav explicitly selected this order for the next session:

1. **Reorganize the repository.**
2. **Integrate and evaluate Images 2.5 for generated visuals, starting with 2D.**
3. **Improve the native geometry and visual vocabulary Astra can generate.**

This handoff records the current implementation work. Stage 1 is implemented and verified; its commit and push are pending. Image and flow features are not implemented. Follow this order even though the earlier visual research suggested improving native flows first.

## Goal and current behavior

Astra Spatial is a generic framework for exploring structures through live conversation and AR. The server rack is its first application, not a special command vocabulary. Arav wants Astra to choose the useful level of detail, generate explanations on demand, and keep context across follow-ups. Avoid hardcoded interpretations of rack/heat/fan phrases or scripted demo animations.

The universal iPhone/iPad app uses one Realtime conversation for typed text and voice. Its `ask_astra` call routes to the backend's Astra authoring path. The native framework validates and installs structured scene changes, acknowledges them, and then releases the final explanation. Imported parts and generated primitives share that scene authority.

Arav successfully pulled out a server, requested a heat-flow explanation and generated arrows on the physical iPhone. Logs confirm three installed edits and completed typed responses, with node counts 20 → 20 → 29 → 33. He reported that the arrows looked low-fidelity. The logs do not retain their exact mesh recipes or images. [Session evidence](docs/evidence/iphone-heat-flow-session.json).

Already completed at the baseline:

- Generic scoped detail expansion, instance identity, hierarchy context and Undo.
- The approved Akeil exterior and source-derived interior packages are bundled; interior decoding is lazy.
- Physical scale is preserved: rack height 2.21 m, root scale 1. Non-AR previews fit the camera instead of shrinking assets.
- One vertically centered composer action morphs from microphone to Send. Hand detection is automatic on physical devices.
- Connection diagnostics, finite deadlines and unsent-draft preservation are implemented.
- Primitive winding and tube-frame defects were fixed in `103f798`. Fourteen focused cases inspect real RealityKit mesh buffers. These fixes are distinct from the richer geometry work below.

## 1. Reorganize the repository

The [structure plan](docs/repository-structure-plan.md) has been applied, with six visible owned directories:

```text
app/                     # Universal native product: UI, conversation, audio
backend/                 # One deployable Node service
framework/               # SpatialCore + SpatialApple Swift package
  contract/              # Language-neutral schema and shared fixtures
assets/                  # Approved geometry, semantic metadata, provenance
tools/                   # Offline asset tools, development and acceptance
docs/
  evidence/              # Dated receipts and screenshots
.local/                  # Git-ignored logs, builds, downloads, dev credentials
README.md
APPROACH.md
HANDOFF.md
```

The working tree moves `apps/ios` → `app`, `services/session` → `backend`, `packages/SpatialKit` → `framework`, `contracts` → `framework/contract`, and `content` → `assets`. Development scripts are grouped under `tools/assets`, `tools/checks`, and `tools/dev-session.py`; evidence and architecture/product/research documents are under `docs`. The three entry documents above remain at the root.

SceneLab and PointingReplay are separate executable targets in one `tools/Package.swift`. PointingReplay's MainActor isolation is preserved in the SwiftPM settings. The public Swift products remain `SpatialCore` and `SpatialApple`; directory names do not require renaming the modules.

Ownership rules: the app owns interaction; the framework owns accepted scenes and native execution; the backend owns model calls and credentials; assets are data; tools exercise production modules. Preserve these boundaries during the move. Do not turn this into a scene-controller rewrite or introduce new processes just to populate folders.

Migration details covered by verification:

- Update XcodeGen dependency/resource paths and regenerate the tracked Xcode project.
- Update SwiftPM local package identity, fixture parent-directory walks, Python root discovery and JavaScript dependency paths.
- Preserve bundled assets, their exact bytes, licenses and all three runtime catalogs. The repository-only source catalog must stay outside the app bundle.
- Preserve the existing private development token when moving `runtime` into `.local`. Existing server processes may still write to old paths; coordinate their restart rather than deleting active runtime state.
- Update current commands and Markdown links, including this handoff. Preserve historical evidence payload paths and hashes as original observations.

**Acceptance passed:** backend typecheck/tests/production build, framework tests, both headless tools, simulator and signed-device builds, bundle digest checks, and an ordinary iPhone launch using the saved endpoint. Commit and push the reorganization before starting image integration.

Backend verification passed typecheck, 115 tests, production build, and the context check. Framework verification passed 69 Swift Testing cases plus six XCTest cases, with four explicit environment-gated skips; the approved app-detail resource case passed. SceneLab validated 179 nodes and 32 geometries; all six pointing replay cases passed. Both app builds passed; all 11 checked bundle resources match the baseline, and the source catalog is excluded. Historical evidence payloads and the private token were preserved byte-for-byte. Both devices have the updated app installed. A fresh ordinary iPhone launch, with no environment injection, reached `connection.finished` with `ready=true` using its saved HTTPS endpoint and Keychain credential. The iPad launch remains unverified because its screen was locked; this does not change the verified iPhone launch. [Migration receipt](docs/evidence/repository-migration.json).

## 2. Integrate the new image API

Read [Images 2.5 research](docs/images-and-spatial-explanations.md), then verify current official API docs and account access. As last verified, `gpt-image-2.5-flare` and `gpt-image-2.5-sunburst` output **raster images**. Start with Flare. Arav is happy with 2D visuals; 3D output is optional if a documented, working capability actually provides it. A 2D image placed on an AR plane is still a 2D illustration. Do not delay this stage for a speculative 3D conversion pipeline.

First vertical slice: while discussing a selected component, Astra can request a useful generated diagram/cutaway, and the app shows the result alongside the conversation or assembly. Use the current server heat-flow explanation as one evaluation case, not as a hardcoded route. The same capability must work with another subject.

Implementation responsibilities:

1. Pass a bounded brief, selected component IDs and accepted scene revision to an illustration job in the **existing backend**. Optionally provide a reference render cropped to the virtual assembly. Keep image API credentials server-side.
2. Start with the direct Image API and one completed image. Add progress from real provider events when supported; do not fabricate progress percentages. Keep native AR and conversation usable while generation runs.
3. Persist output bytes as an immutable artifact with ID/checksum, MIME type, pixel dimensions, model/provenance and source scene revision. Cache by hash; do not put base64 image payloads into every scene snapshot or model context. Use bounded image dimensions and retained storage/cache budgets.
4. Begin with an app-level explanation panel. If spatial placement adds value, add a typed, approved image resource and textured plane through the normal resource-validation path. Images must not replace editable source geometry or silently flatten its hierarchy.
5. Bind job completion to the correct request/component/scene. A late result must not attach to a changed scene; cancellation and retry must not replay an already installed scene mutation.
6. Make the capability model-driven through an explicit tool/proposal change. The current backend expects exactly one completed `propose_scene` call; silently appending an image tool to that request violates its existing contract. Keep illustration job state separate from scene installation receipts.

**Acceptance:** measure real first-preview/final latency, response size, component fidelity, label/direction correctness and edit consistency. Demonstrate generation from live scene context, a follow-up refinement, cancellation, stale-result handling and cache reuse. Verify on iPhone/iPad; record what is observed rather than assuming the launch's relative latency claim means instant results. If the API is unavailable, document the actual failure and keep a clean capability boundary—do not label a mock as integration.

Official references: [launch](https://openai.com/index/introducing-chatgpt-images-2-5/), [Flare](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare), [Sunburst](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst), [image generation guide](https://developers.openai.com/api/docs/guides/image-generation).

## 3. Improve generated native geometry

The current authoring vocabulary has straight arrows, static polyline tubes and solid physically based materials. It lacks flow bindings, smooth arrow paths, readable labels and motion cues. Give Astra better semantic controls instead of asking it to compose increasingly elaborate diagrams from many primitive nodes.

Start with a **generic flow annotation**: stable identity, parent/visibility, source and target node IDs with local attachment points, optional route points, direction, width/style and a short label. Supply host-derived local bounds and optional attachment metadata so the model can place its output using actual geometry context. No hardware-specific branches.

Native rendering should provide smooth paths and correctly oriented arrowheads, a legible annotation material, a bounded pool of moving markers and optional anchored text. Cache geometry and arc-length sampling; update marker transforms locally, without rebuilding meshes or calling the model each frame. Preserve physical scale and ancestor transforms.

Carry annotations through the same versioned contract, validation, IDs, accepted-state, receipts and Undo rules as other content. Make “reverse this,” “move that part,” “hide this path” and follow-up explanations refer to the existing annotation's identity. Image panels from stage 2 complement these editable 3D objects.

**Acceptance:** exercise the feature on the rack and a non-rack fixture; move/rotate/scale bound parts and ancestors; verify attachment, reversal, deletion, Undo and Reduce Motion behavior. Retain the primitive regression tests. Measure actual device frame cost and geometry/memory bounds with several simultaneous flows. A successful simulator render does not establish physical AR performance.

Apple references and API choices are collected in [the visual research](docs/images-and-spatial-explanations.md). Begin with cached `MeshDescriptor` geometry and local animation; introduce low-level mesh/shader machinery only for a demonstrated need.

## Working environment and first actions

- Canonical checkout: `/Users/aravb/Developer/astra2026`; the earlier Documents/ChatGPT path is a symlink. Verify the checkout, branch and dirty state before editing. Continue committing and pushing to **`Arav`**, as Arav requested.
- OpenAI key: use Doppler CLI, project `backend`, config `dev`, selecting `OPENAI_API_KEY`. Never print credentials or add them to commits. The local session token is separate and now stored in ignored `.local/dev-session.json` plus device Keychain.
- The direct phone-to-Mac LAN route failed. An authenticated HTTPS/WSS tunnel to the same service succeeded. This remains a temporary Mac-dependent route, not a deployed cloud backend. Inspect running processes and saved configuration on resume; do not assume an old tunnel URL or PID remains valid. [Endpoint notes](docs/backend-endpoint.md).
- Devices: iPhone 15 Pro and iPad Air 13-inch M4, with developer trust already configured. Both use the same universal app. The last baseline rollout encountered locked screens; verify availability rather than repeating trust setup. The last primitive-fix builds passed but their physical visual recheck is pending.
- Current migration checks: 115 backend tests; 69 Swift Testing cases and six XCTest cases, with four explicit environment-gated skips. Both app builds and the ordinary iPhone launch passed. Docker deployment files exist; the image has not been built because the daemon was unavailable.

Current commands from the repository root:

```sh
swift test --package-path framework --scratch-path .local/build/framework
npm --prefix backend run typecheck
npm --prefix backend test
npm --prefix backend run build
swift run --package-path tools --scratch-path .local/build/tools SceneLab validate assets/server-rack/scene.json
swift run --package-path tools --scratch-path .local/build/tools PointingReplay --all
python3 tools/dev-session.py doctor
```

Commit and push the verified stage 1 before starting image integration. Independent review, image API study and geometry design can proceed in parallel while edits remain assigned to clear owners. Update `APPROACH.md` as a sequential Arav/Astra collaboration log, not a replacement architecture specification. Commit coherent, verified stages and keep this handoff current as they finish.
