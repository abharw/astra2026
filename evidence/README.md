# Acceptance evidence

2026-09-08. These runs distinguish real provider calls, deterministic tests, and device observations. No API keys or ephemeral voice credentials are included. Local logs and device captures stay in ignored `evidence/local/`.

## Real Astra → Swift reducer

`tools/SceneLab` connected to the real local service, which called `gpt-6-astra`. The client used `SceneWireDecoder` and `SceneState` from the production Swift package, sent the resulting receipts, and waited for the backend explanation. It did not render, simulate AR, or measure display latency.

| Run | Observed result | Elapsed request-to-explanation |
| --- | --- | --- |
| [Fan creation](live-fan.json) | Five nodes: a group, cylindrical hub, three separately editable blades sharing geometry; accepted → installed → completed | 24.13 s |
| [Rack deconstruction](live-rack-explode.json) | Only existing `server-1` moved, to `[0, 0.13, 0.25]`; CPU and two RAM nodes added; 15 nodes total | 15.36 s |
| [Explanation only](live-explanation.json) | Twelve starting nodes unchanged, revision remained zero, no mutation receipts | 10.10 s |
| [Detailed rack deconstruction](live-detailed-deconstruction.json) | 179-node reference-based seed; only server, cover, and fan-wall local transforms changed, preserving all children | 9.25 s |

The fan used the initial reasoning configuration. Later runs used low reasoning effort. These are different prompts and isolated samples; they do not establish a controlled speed comparison or a latency percentile.

The detailed asset uses 32 shared geometry definitions and 13 materials, with 2,644 expanded visible triangles. Its compact snapshot is 81,220 bytes. Dell R760 dimensions and component topology inform the seed; internal geometry and the tabletop rack are explicitly schematic. Source references and regeneration instructions live in [the example](../examples/server-rack/README.md). The first three runs above used the earlier 12-node seed, which remains recorded in their evidence documents.

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
