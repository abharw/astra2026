# Acceptance evidence

2026-09-08. These runs distinguish real provider calls, deterministic tests, and device observations. No API keys or ephemeral voice credentials are included. Local logs and device captures stay in ignored `evidence/local/`.

## Generic detail expansion and live follow-up

[Live detail acceptance](live-detail-acceptance.json) records two production app turns through Realtime and Astra: expand just one imported instance, then lift its heatsinks and add a generated arrow. The [expanded assembly](simulator-live-detail-expansion.png) and [child-level follow-up](simulator-live-detail-followup.png) were inspected in the iPhone simulator. Typed submission to final text took 11.968 and 12.819 seconds. These are single observations, not a speed benchmark.

[Native installation](native-detail-installation.json) verifies 20→29 nodes, preserved target identity/current pose, unchanged other instances and Undo using the exact bundled packages. [Interior resource validation](server-detail-native.json) checks materials, bounds and 76 source-derived selection boxes. [Proxy evidence](server-selection-proxies.json) records their source membership and coordinate basis. Physical AR performance, microphone quality and screen-space hand selection remain separate checks.

## Real Astra → Swift reducer

`tools/SceneLab` connected to the real local service, which called `gpt-6-astra`. The client used `SceneWireDecoder` and `SceneState` from the production Swift package, sent the resulting receipts, and waited for the backend explanation. It did not render, simulate AR, or measure display latency.

| Run | Observed result | Elapsed request-to-explanation |
| --- | --- | --- |
| [Fan creation](live-fan.json) | Five nodes: a group, cylindrical hub, three separately editable blades sharing geometry; accepted → installed → completed | 24.13 s |
| [Rack deconstruction](live-rack-explode.json) | Only existing `server-1` moved, to `[0, 0.13, 0.25]`; CPU and two RAM nodes added; 15 nodes total | 15.36 s |
| [Explanation only](live-explanation.json) | Twelve starting nodes unchanged, revision remained zero, no mutation receipts | 10.10 s |
| [Detailed rack deconstruction](live-detailed-deconstruction.json) | 179-node reference-based seed; only server, cover, and fan-wall local transforms changed, preserving all children | 9.25 s |

The fan used the initial reasoning configuration. Later runs used low reasoning effort. These are different prompts and isolated samples; they do not establish a controlled speed comparison or a latency percentile.

The detailed asset uses 32 shared geometry definitions and 13 materials, with 2,644 expanded visible triangles. Its compact snapshot is 81,220 bytes. Dell R760 dimensions and component topology inform the seed; internal geometry and the tabletop rack are explicitly schematic. Source references and regeneration instructions live in [the content source](../content/server-rack/README.md). The first three runs above used the earlier 12-node seed, which remains recorded in their evidence documents.

## Imported USDZ asset

The app's default imported rack is the approved bundled Akeil USDZ described by [the app catalog](../content/imported-rack/app-catalog.json). Its SHA-256 `assetID` is `sha256:b1ae63bb5e95a52152dba08574b0e6b852ec9499fb1e0cf63360e96e3f31bad1`; the bundled file is 13,232,052 bytes with approximately 2.99 million expanded triangles. Native validation confirms the 18 server bindings retain source vertices, normals, and materials, with the independently verified PSU6 correction. The app decodes this disk asset lazily when Load rack is selected and has no initial network dependency. The raw pinned URL and provenance remain in [the source catalog](../content/imported-rack/source-catalog.json). No automatic LOD or runtime selective-detail policy is implemented; processing variants are separate evidence and are not the default. The raw interior is absent and remains only in `.blend` source material, with no lazy interior loader currently implemented.

[The imported rack screenshot](simulator-imported-openrack.png) shows the 18-server rack in the production simulator app. This screenshot is rendering evidence, not a mobile frame-rate measurement. [Processing evidence](mobile-rack-validation.json) records derivative experiments; [processing instructions](../content/imported-rack/PROCESSING.md) describe fidelity tradeoffs and licenses. The app intentionally defaults to the faithful bundled branch, not an automatically selected derivative.

## Unified Realtime text and voice

The refined composer keeps the microphone control persistent while text is sent; [the keyboard-state capture](simulator-composer-keyboard.png) and [the refined composer capture](simulator-refined-composer.png) record this simulator UI behavior. They do not establish physical voice or gesture acceptance.

[Native Realtime evidence](native-realtime-tool.json) records a real typed app turn through Realtime, Astra, a native scene installation receipt, and final Realtime text. This earlier acceptance used the procedural rack. [The provider tool smoke](realtime-tools-smoke.json) instead uses synthetic tool outputs and verifies text/audio protocol sequencing; it does not prove microphone or speaker behavior.

[Physical iPhone endpoint connection](iphone-endpoint-connection.json) records the same signed app reaching `session.accepted` and Realtime `ready` through the authenticated HTTPS/WSS route in 2.212 seconds. The direct LAN route failed in that check. This proves connection setup only; it does not establish a completed model turn, microphone quality, or physical AR performance.

The first rack attempt exposed an unnecessarily restrictive alias rule; the first fan attempt exposed a provider-schema/normalization mismatch. Both were corrected before the passing runs. API streaming is real, but the current service waits for completed function arguments before installing a proposal.

## Other checks

- Swift package tests cover validation, immutable retries, stale epochs, scope ownership, generation sequencing, native mesh compilation/entity identity, pointing locks, and SQLite recovery boundaries.
- Node tests cover the Swift/TypeScript hash vectors, stale model results, bounded proposal repair, receipt gating, and explanations without scene mutation.
- `scripts/realtime-smoke.mjs` used a real backend-issued ephemeral credential and real `gpt-realtime-2.1`. The current PCM configuration was accepted and a synthetic text input produced completed audio output. This does not establish the physical microphone, speaker, echo, or interruption behavior.
- The universal app built for simulator and physical iOS. A signed build installed and launched on the iPad Air 13-inch (M4), iPadOS 26.5; the rear-camera view was inspected through QuickTime's USB screen preview.
- Six synthetic gesture replays use the production mapper/resolver. Following the completed-result starvation fix and visible ring overlay, Arav reported that the ring tracks his fingertip and turns green over a part on the physical iPad. This is user-observed hardware feedback, not measured accuracy across rotations or spoken target-locking evidence.
- Computer control exercised the actual iPad simulator UI against the live service: Load rack → Connect → request one server move plus CPU/two RAM modules → inspect changed RealityKit scene → Undo → inspect restored rack. Local screenshots are `evidence/local/simulator-live-rack-edit.png` and `evidence/local/simulator-live-rack-undo.png`. This verifies the native non-AR rendering/UI path separately from physical camera behavior.
- A second native UI run loaded the detailed 179-node assembly and submitted a fresh natural-language request to move its cover, chassis, and six-fan wall. [The resulting RealityKit screenshot](simulator-detailed-deconstruction.png) shows exposed internals. Undo restored the original assembly and removed the stale explanation. The universal build containing the canonical seed installed on both the iPad and iPhone; Arav enabled the required developer trust on each device.

These generated scenes are evidence fixtures. The live service never looks up their prompts or files to answer a user.

## Historical records

[Faithful exterior native validation](faithful-exterior-native.json) and [the earlier imported Realtime run](native-imported-realtime.json) are retained chronology. They predate the current shipped root-scale-1 faithful rack and must not be used as evidence for its shipping scale or current app behavior.
