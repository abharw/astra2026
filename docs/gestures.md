# Pointing: required demo milestone

2026-09-08 · Arav clarified that pointing must be demonstrated. It may follow the first working voice/generation slice, but it is required for demo acceptance. Pinch, dragging and other manipulation remain optional. Target one native app for supported iPhones and iPads. The resolver, Vision adapter, native ARFrame wiring, and speech binding are implemented. Synthetic tests pass. After fixing completed-result starvation and adding a visible cursor, Arav confirmed on the physical iPad that the ring follows his fingertip and turns green over a part. This first success is not a measured accuracy or combined voice result. iPhone usability is now a priority for audience participation.

## First interaction: point and speak

Arav selected screen-aligned pointing for the first implementation: a small cursor follows the index fingertip in the rear-camera view. Point until a component is visibly highlighted, then say “explain this,” “separate this,” or “make another one beside it.” Beginning the spoken request locks the stable target. Astra receives that component's identity and the request. A pinch can optionally lock a selection before speaking, but is not required for the pointing demo.

The hand chooses the subject; Astra decides the requested explanation or generated change. Selection and feedback happen locally, without waiting for a model call. Touch and a screen reticle remain available as fallback inputs; demonstrating only those does not satisfy the pointing requirement.

The agreed baseline is a camera-view cursor: it casts from the camera through the fingertip's screen position into virtual geometry. It does not infer the physical direction of the finger through the room. Full three-dimensional pointing is outside this first requirement; two-dimensional landmarks alone do not establish finger depth or a physical pointing ray.

## iPad demonstration setup

Use the same app on iPhone and iPad. Arav's iPad Air M4 on iPadOS 26.5 is the primary demonstration target; validate the actual interaction before recording. A teammate can hold it in landscape beside Arav so he can see the display and reach a hand into the rear camera's view. A stand is another option. If the presenter stands opposite the tablet looking at its back, he cannot see the virtual part or selection feedback; that setup needs a mirrored display or a different interaction design.

The iPhone uses the same ARSession → Vision → viewport mapping → RealityKit hit-test pipeline. It needs a compact layout and a one-hand-holds/one-hand-points trial, not a second tracking implementation. Foreground hand sampling is automatic on physical devices; this input is a fingertip cursor and does not yet classify a deliberate pointing pose versus an open palm. [Apple and working-source references](hand-tracking-references.md) distinguish this iOS path from visionOS hand anchors.

A larger screen and separate holder may improve aim and presentation, but holder motion, hand occlusion, screen visibility and speech capture need testing. Do not assume the tablet establishes depth or requires LiDAR. See [device support and hardware policy](devices.md).

## Native implementation boundary

1. Sample frames from the existing AR session; do not start a competing camera capture pipeline.
2. Use Apple's Vision hand-pose detection for one visible hand. Vision provides hand landmarks; a custom gesture classifier is an additional option, not a prerequisite. [Apple's hand-pose pipeline](https://developer.apple.com/videos/play/wwdc2021/10039/).
3. Transform image landmarks into the displayed AR viewport, accounting for orientation, crop and any mirroring. Retain frame timestamps and reject stale observations.
4. Smooth the cursor and hit-test selectable native geometry. Use simple picking proxies where needed. Convert the native entity result into a semantic `nodeId`. [RealityKit entity selection](https://developer.apple.com/documentation/realitykit/arview/entity%28at%3A%29).
5. Resolve a stable hover target into an explicit selection when the person starts the spoken request. If optional pinch confirmation is implemented, use thumb/index separation normalized to hand size, separate close/open thresholds and confidence checks.
6. Emit ordinary selection events into the existing SDK. Pointing recognition contains no server-rack knowledge and cannot directly bypass the scene executor.

Limit inference to bounded work with at most one active prediction and a latest-frame slot. Do not accumulate frames or apply out-of-order results. The cursor/render loop continues independently of inference frequency. Neural Engine execution and its benefit remain profiling questions; invoking Vision alone is not evidence of either. See [the local-inference decision](renderer-choice.md).

## Intent and accidental activation

Hover is temporary visual feedback; it does not change the scene revision or cancel generation. Hand loss hides the cursor and clears hover but preserves an already confirmed selection. For optional pinch confirmation, latch the stable hover target at pinch onset so the fingers moving together cannot choose a neighbor. Require release before another pinch and again after reacquisition, so a returning closed hand cannot trigger twice.

Keep hand tracking foreground-only so ordinary background activity does not change targets. If tracking confidence is insufficient, show unavailable cursor state and accept touch instead of guessing.

Bind each spoken request at speech start to the fresh stable hover target, or an explicitly locked selection when no pointing attempt is active. Capture scene identity, node ID, selection-event identity and the observation timestamp. Use local audio/selection timing; do not substitute whatever happens to be hovered when a delayed cloud tool call arrives. The initial interaction requires pointing before beginning speech. Later hover must not silently retarget an in-flight request. An uncertain attempted point must not silently fall back to an old selected part; resolve ambiguity before mutation. Revalidate that the referenced node still exists when admitting the scene request.

Selection is UI state, not an authored geometry edit. Speech still follows the existing pause/correction rules; gesture selection alone does not advance the generation epoch.

## If time remains: pinch and drag

Only after selection works reliably, add a separate manipulation mode for the selected part. Pinch and hold, move within an explicit view-facing plane established at drag start, and release to commit. Display this constraint; do not infer depth movement from hand size.

Starting manipulation revokes competing generation before acquiring scene-write ownership. Keep drag movement as local preview and commit one absolute transform through the existing validated transaction path on release, producing one undoable edit. Resolve world-to-parent coordinates explicitly. Hand/tracking loss, app interruption, explicit cancel, competing touch or speech start cancels the preview and restores the accepted pose while preserving selection. Block conflicting scene installation during the preview. Model context and narration must distinguish preview from committed state.

Do not put two-handed scaling, free-space six-degree manipulation, a gesture vocabulary, or custom model training into the first gesture milestone. Those are separate experiments.

## Acceptance and demo value

Run a small pointing feasibility trial early, in parallel with building the core voice/generation slice, to expose ergonomic or tracking problems before demo preparation. Integrate the required pointing-to-voice path after the core slice works. Compare touch/reticle and hand selection on large and small parts, with different hand positions and lighting. Record correct selections, wrong-target requests, cursor stability, hand-loss recovery, frame time and audio continuity. Test the teammate-held iPad, speaking while moving naturally, and older hand observations arriving after the tablet moves.

Required demo evidence: point at a newly generated component, ask an unfamiliar follow-up, and receive a correct explanation or edit of that component while unrelated parts remain intact. Failure to make pointing reliable leaves that demo requirement unfinished; it must not be silently dropped or relabeled optional. The SDK still treats pointing as an input adapter rather than another scene authority.
