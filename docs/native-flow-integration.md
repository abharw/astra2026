# Native flow annotations

September 8, 2026. Implemented after the image integration checkpoint `8d93cb3`. Real model authoring and the production Swift reducer passed the rack and non-rack lifecycle checks. The full native test suite, both app builds, real-model native rack interaction, and 0/1/8/32-flow simulator and physical iPhone metrics passed. The successful physical run followed a four-sample baseline interrupted by an audio callback crash; earlier device launches failed with `Locked`. These dated results measure CPU time, callback cadence, and resources. Physical visual, anchoring, GPU, and thermal acceptance remain open. [Compact integration evidence](evidence/native-flow-integration.json).

## Contract and ownership

A flow is a [typed geometry recipe](../framework/contract/README.md#flow-binding-and-lifecycle) on an ordinary scene node, advertised through `flow.v1`. It has the node's stable identity, parent, material, visibility, provenance, transaction receipts, and Undo behavior. The recipe contains source/target structural node IDs with local attachment points, zero to eight route points, forward/reverse direction, width, a short label, and an animation flag. Width is 0.001–0.25 metres in annotation space; labels are capped at 80 UTF-8 bytes, and a scene may contain at most 32 flow instances, including hidden ones.

Endpoint points belong to their structural nodes; route points belong to the annotation node. The native renderer resolves the full candidate translation/rotation/scale hierarchy as `inverse(flowWorld) × endpointWorld × localPoint` before installing any change. Accepted endpoint or ancestor movement therefore changes the derived path without replacing the flow node; arbitrary direct edits to RealityKit entities outside scene installation are not a second binding authority. Reversal traverses the same bound path in the opposite direction. The annotation illustrates a relationship; it is not a heat, fluid, or electrical simulation.

The [backend adapter](../backend/README.md#session-wire) retains one completed `propose_scene` call. A semantic flow request normalizes into the existing geometry/material/node operations; follow-up recipe replacement keeps the annotation node identity. Clients without `flow.v1` cannot receive flow creation or reuse. Existing recipe encodings and v1 canonical hash vectors remain unchanged; the new recipe has a documented Swift/TypeScript canonical field order.

Endpoints must exist, be structural, and lie outside flow subtrees. A flow cannot bind to itself or its descendants. Shared recipes are checked per live node instance. Removing a bound structural node must remove dependent annotations in the same transaction; otherwise the whole transaction is rejected. `removeNode` is nonrecursive. Hiding, deletion, and Undo use the existing scene operations rather than a separate annotation store.

The app can supply up to 128 measured `nodeLocalBounds` records in its scene snapshot. Native bounds include hidden structural geometry and transformed structural descendants, exclude flow geometry and renderer helpers, and omit empty or nonfinite results. The backend validates records against the exact snapshot before admitting them to model context. Bounds are contextual measurements, outside scene documents and canonical request hashes. The headless live checks below deliberately supply no bounds because they have no renderer.

## Native rendering

The [path compiler](../framework/Sources/SpatialApple/Rendering/FlowPath.swift) builds a smooth path capped at 128 samples, with stable transported frames, eight radial segments, and a terminal arrowhead. Duplicate/backtracking points are handled without invalid vertices. Coincident transformed endpoints preserve scene identity and suppress the degenerate path, arrowhead, and markers.

The [renderer](../framework/Sources/SpatialApple/Rendering/FlowRenderer.swift) caches paths, label meshes, arc lengths, and shared marker geometry. Preparation enforces expanded budgets of 500,000 vertices and 250,000 triangles. Installed caches retain only resources referenced by the current scene. Paths use the node's unlit material color; labels use larger cached white native text on a billboard near the path midpoint, backed by a shared dark plane scaled to the text bounds. The backing is shared geometry and is included in resource accounting. Up to four markers per flow advance using world-space arc lengths at a nominal 0.12 m/s, with frame-step clamping after long pauses. Normal updates change marker transforms, not meshes or model calls.

Reduce Motion disables markers while preserving the static path and label. The renderer toggle is covered by native tests and connected to SwiftUI's accessibility environment; changing the operating-system preference in a running app was not exercised. A retained scene-update subscription follows the attached view and is cancelled on detach/replacement. Geometry, physical scale, visibility, and ancestor transforms remain governed by the accepted scene.

## Live authoring acceptance

[The live command](../tools/checks/check-flows.mjs) used actual model-selected proposals over the product WebSocket and a persistent `SceneLab reducer` process running production `SpatialCore.SceneState` and `SceneWireDecoder`. The two fixtures were the authored 179-node procedural rack and a three-node synthetic lamp. This does not use the imported rack CAD, native measured bounds, or camera observations.

Each fixture passed five model turns and one host Undo, preserving the same flow ID through the lifecycle:

| Stage | Verified behavior | Rack | Lamp |
| --- | --- | --- | --- |
| Create | One forward flow, 0.008 m width, local endpoints at zero, no route points, existing structure preserved | 4.004 s | 2.926 s |
| Reverse | Direction changes on the same node; bindings and remaining recipe fields preserved | 4.873 s | 4.740 s |
| Move bound part | Source translates by `[0.05, 0.02, 0]` m; rotation, scale, flow identity and recipe preserved | 2.879 s | 2.682 s |
| Hide | Only the annotation's visibility changes | 3.014 s | 2.434 s |
| Delete | Only the annotation is removed | 2.276 s | 2.541 s |
| Undo | Host operation restores the exact pre-deletion document, including the hidden annotation | 0.005 s | 0.002 s |

All 12 stages passed in 32.459 seconds overall. These times are harness request-to-accepted-result timings, not rendering or conversational UI latency. Every stage advanced the accepted revision; Undo restored the pre-deletion document hash at a new revision. Translation acceptance proves retained bindings in scene data; actual path movement requires the separate native tests and visual checks. The evidence retains flow IDs, proposal hashes, scene hashes, and local receipt/artifact checksums without copying the rack's full Undo node list.

## Native acceptance and metrics

The framework check for this stage passed **138 Swift Testing cases and six XCTest cases**, with four explicit environment-gated skips. The approved bundled app-detail test was enabled and passed. Backend checks passed 206 tests, and simulator plus signed-device app builds passed. A narrow initial-handshake race was reproduced and fixed: an early session acknowledgement can now arrive before the hello send returns; six bridge tests cover that boundary. Both physical devices received that signed build.

The physical receipts establish this order on September 8 (UTC): metric launches on both devices failed with `Locked` at 22:34, before collecting samples. An ordinary iPhone launch later succeeded without injected endpoint or fixture settings; the recorded ordinary iPad launch remained locked. An iPhone zero-flow baseline began at 22:48:10.581 and collected four samples over 4.100 seconds before a system-reported `EXC_BREAKPOINT`/`SIGTRAP` at 22:48:14.804. Swift actor isolation was asserted in the audio input-tap callback on the audio queue; counts 1/8/32 were not attempted in that run. This is not evidence of a flow marker-loop crash. A separate retry then completed all four counts from 22:50:07.096 through 22:52:41.190, before the subsequent audio callback fix. The successful measurements below preserve their own timestamps and hashes; they do not accept later audio changes. Launch and connection readiness do not establish physical visual acceptance.

Computer control observed the one-flow synthetic fixture in the iPhone simulator: a curved cyan line and “Flow 1” label appeared between two structural chambers. Its saved backend route was unavailable and the app displayed a connection error, while rendering and the independent sampler continued. This observation establishes native fixture presentation, not a live conversation result. The 32-flow stress fixture also showed all colored paths and moving markers, but many labels overlapped substantially. Rendering that count does not establish readable annotation density. A later live native rack check found poor label contrast, prompting the label refinement described below.

The Debug-only [acceptance fixture](../app/AR/SpatialDemo/DebugFlowAcceptance.swift) activates only for `ASTRA_FLOW_ACCEPTANCE_COUNT=0`, `1`, `8`, or `32`. It installs a named, synthetic non-rack transfer manifold through the production scene/controller/renderer and makes no model request. Ordinary launches do not activate it. Each count gathers 30 one-second observations while the original fixture remains installed in an attached, active view; inactivity, replacement, or scene changes cancel the run.

The [metric collector](../tools/checks/check-flow-metrics.py) restarts the installed Debug app for each requested count, then checks sample ordering, duration, resource bounds, callback progression, and unchanged mesh-rebuild count during animation. It reports marker-loop CPU wall time and `SceneEvents.Update` callback intervals. Timing snapshots use a bounded 300-event rolling buffer: their p95 values are not a whole-session GPU frame-time distribution. The host's 36-second wait allows startup and collection; it is not itself a performance measurement. Simulator receipts are explicitly labelled `simulator`, separate from `physicalAR` receipts. Resource metrics count retained unique meshes, while admission budgets count expanded instances. `markerCount` counts allocated marker entities even when animation disables them. `visibleFlowCount` counts ancestor-enabled nodes, including degenerate flows; it is not a camera visibility or occlusion measurement.

## Live native rack check

The actual iPad simulator app also completed real-model edits against its bundled imported rack. The first request pulled server01 forward and added a cyan “Airflow” annotation; native installation reached revision 1 with 21 nodes in 7.960 seconds after scene request submission. A follow-up request lifted the bound server; installation reached revision 2 with 21 nodes in 2.774 seconds. Computer control observed the flow path and moving markers follow the server. The requested translations were 0.6 m forward and 1 m upward; logs verify installation and node counts, while rendered coordinates were not independently measured.

A subsequent native reversal screenshot shows the cyan arrowhead toward the server front and visible white marker spheres. That local screenshot is checksum-referenced in the integration evidence and remains uncommitted. This check exposed unreadable white label text over the silver chassis. Larger text with a cached dark backing is now implemented and passed a fresh live rack check. The [saved final screenshot](evidence/native-flow-rack.png) shows a clearly readable “Airflow” label over the silver chassis, with the cyan curve and white markers preserved. That new model request installed revision 1 with 21 nodes in 6.110 seconds. This verifies one simulator view; it does not guarantee label readability at every viewpoint or solve dense-label overlap. The final 0/1/8/32-flow metrics rerun also passed after this change. Earlier screenshots and benchmark results remain dated in the evidence rather than being relabelled as final-design acceptance.

## Recorded simulator metrics

After the label refinement, all four iPhone 17 Pro simulator runs on iOS 26.5 passed 30 ordered one-second samples, spanning 30.67–31.06 active seconds each. The final statistics below cover each run's latest 300 callbacks, rather than all 30 seconds. All sampled windows had zero mesh rebuilds during animation.

| Flows | Allocated markers | Mean marker CPU ms | p95 marker CPU ms | Retained vertices | Retained triangles |
| --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0.002170 | 0.003625 | 0 | 0 |
| 1 | 4 | 0.063754 | 0.091167 | 2,471 | 3,382 |
| 8 | 32 | 0.149140 | 0.226125 | 23,295 | 30,112 |
| 32 | 128 | 0.401013 | 0.591917 | 104,355 | 130,930 |

Mean scene-update callback intervals were approximately 16.667 ms for each count; the 32-flow final-window p95 was 16.685 ms. The largest case retained 66 unique meshes, including the shared label backing, within the checked budgets. Both iPhone and iPad simulators were running on the host; these observations are not isolated hardware measurements. The final benchmark supplied existing development configuration silently so the earlier connection-error panel was absent.

This table measures simulator callback cadence and instrumented marker-loop wall time. The earlier 32-flow visual stress run exposed substantial label overlap; the backing improves contrast but adds no collision-avoidance layout. The compact evidence preserves the earlier pre-label benchmark, locked physical launches, and incomplete crashed baseline separately.

## Recorded physical iPhone metrics

The physical retry on iOS 26.6.1 passed all checks for counts 0/1/8/32, with 30 ordered one-second samples per count spanning 30.51–30.70 active seconds. It used the synthetic Debug fixture after label refinement and before the audio callback fix. The receipt records `surface: physicalAR`; this names the running surface, not visual or anchoring acceptance. Its SHA-256 is `aa78d8a4cd839b99792348368cd12d1d3a670c01e5d01b591564aec263e752ff` (local path `.local/flow-metrics/iphone-physical-retry/receipt.json`).

These are each run's final rolling 300-callback statistics, not whole-run timing percentiles:

| Flows | Markers | Mean CPU ms | p95 CPU ms | Mean callback ms | p95 callback ms | Retained vertices | Retained triangles |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0.003995 | 0.003875 | 16.667 | 17.823 | 0 | 0 |
| 1 | 4 | 0.080695 | 0.141708 | 16.671 | 17.700 | 2,471 | 3,384 |
| 8 | 32 | 0.387201 | 0.581917 | 16.669 | 17.614 | 23,297 | 30,142 |
| 32 | 128 | 0.586791 | 1.000250 | 16.674 | 19.006 | 104,383 | 131,142 |

Every sampled window had zero mesh rebuilds during animation. The largest case retained 66 unique meshes within the checked budgets. Physical resource totals are retained as measured rather than substituted with simulator counts. These runs establish instrumented marker-loop CPU wall time and scene-update callback cadence on that device and build; they do not measure GPU time, thermal soak, pointing accuracy, physical label readability, or AR anchoring. The four samples from the earlier audio-crashed baseline remain unqualified and are excluded from both metric tables.

## Reproduce

Run from the repository root. Build the acceptance client, optionally validate fixtures without a provider call, then exercise the running backend:

```sh
swift build --package-path tools --scratch-path .local/build/flow-check --product SceneLab
node tools/checks/check-flows.mjs --prepare-only
node tools/checks/check-flows.mjs --out .local/flow-acceptance/live
```

The live command silently uses the configured endpoint/token, gives each model turn a finite deadline, and writes receipts plus accepted scene JSON only beneath `.local/`. `--fixtures rack` or `--fixtures lamp` narrows the subjects; `--through create` stops after creation. Undo uses the production host operation and makes no model call.

With the Debug app installed, run native metrics using a new output directory:

```sh
python3 tools/checks/check-flow-metrics.py \
  --simulator-id <SIMULATOR_UDID> --counts 0,1,8,32 \
  --out .local/flow-metrics/simulator

python3 tools/checks/check-flow-metrics.py \
  --device <DEVICE_ID> --counts 0,1,8,32 \
  --out .local/flow-metrics/device
```

The physical command requires an available unlocked device. It preserves the app's saved endpoint settings and records launch or lock failures as failures. A valid receipt still establishes only its measured CPU/callback/resource boundary; inspect visible attachment, reversal, labels, Reduce Motion, and AR behavior separately.
