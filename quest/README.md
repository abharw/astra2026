# Spatial Assembly for Quest 3

Native Unity/OpenXR prototype: point with a right hand or controller, capture the actual left passthrough camera image, search technical references, and generate an editable component assembly at the measured surface. Quest 3/3S camera support is required; this does not run through Quest Link camera passthrough.

## Build and install

1. Install Unity **6000.3.23f1** with Android Build Support (SDK/NDK and OpenJDK).
2. Set up the shared Mac bridge using [native setup](../spatial-assembly/README.md). Run `python3 spatial-assembly/configure.py https://YOUR-TUNNEL-HOST` from the repository root. This writes private pairing files for both clients. It preserves the existing bridge token unless `--rotate` is supplied.
3. Open this Unity project and allow package import. Dependencies include Meta MRUK/Core **85.0.0**, OpenXR **1.15.1**, and Newtonsoft **3.2.1**.
4. Choose **Spatial Assembly → Build Android APK**. `SPATIAL_APK` can override the output path. The build command also generates the scene and registers the checked-in XR settings.
5. Enable Developer Mode, connect Quest 3 by USB, and accept the debugging prompt inside the headset. Use `adb devices` to verify it is authorized.
6. Install with `adb install -r /path/to/spatial-assembly-quest.apk`, then launch **Spatial Assembly** from Unknown Sources.
7. Allow camera and spatial-data permissions. Allow microphone access when enabling voice. Use a well-lit mapped room; keep the bridge and HTTPS tunnel running.

The private APK embeds a scoped bridge credential, never the OpenAI API key. Do not redistribute a paired APK. Source checkout intentionally omits connection files. Selected camera frames and enabled microphone audio are sent to OpenAI via the Mac bridge.

## Controls

The panel is an instruction/status guide with no interactive buttons. It follows the wearer with a positional dead zone and smoothing. See the [live headset and casting test record](../docs/QUEST_LIVE_TESTING.md).

- **Right trigger** on a real surface locks that physical referent only. It does not start a scan. On a generated component it selects that component without exploding it. Voice receives this explicit selection.
- **Right thumbstick click** confirms a scan of a selected physical target; with a generated item selected, it returns that item to its original anchored position, rotation and scale. An explicit voice request can also start reconstruction.
- **Right grip** over a generated component grabs the model. A distant selection eases toward the hand, so you do not need to drag it across the room. You can also select once, aim elsewhere, then hold grip to bring that selection closer. Move the controller and release to drop. While holding, trigger places the held model against the measured surface. After release, trigger can select another object.
- Tracked right-hand pinch selects targets; pinching a generated model grabs it until release.
- **A** toggles explode/assemble. **B** toggles voice. **X** explains the next part. **Y** immediately cancels while reconstructing; while idle it researches and rebuilds the selected object.
- **Left grip + X** deletes the selected generated object and its saved record. **Left grip + Y** cancels reconstruction.
- **Left stick click** hides/shows the guide. **Left grip + left stick click** retries saved-anchor restoration.
- Twist the held controller/hand to rotate freely. Right stick left/right turns the model; up/down adjusts distance. Hold left grip and use up/down to tilt. **Left grip + A** brings the selected item within reach without holding it. Large objects are reduced to an inspection size; Return restores their original scale as well as position. After release, the stick can still move/rotate the selected extracted model. Say “return the object” to restore its saved source pose.
- The main bridge reconnects automatically. Voice displays errors and B retries. The optional Mac test connection starts disabled in the current build. **Left grip + B** can explicitly toggle it; the agent must not use it without renewed authorization.
- Say “explode this,” “explain this part,” “reconstruct that,” or “find a schematic and improve it.” Actions report success only after the app acknowledges them.

These controls are implemented and build-checked. Physical grip comfort and input acceptance on the latest build remain pending; see the test record for the last observed runtime state.

## What the headset measures

The pointing ray intersects Meta environment depth. The target is projected into the physical camera image using the image-associated camera pose and calibrated API projection. Capture freezes the target, normal, pose and corner rays; later head movement does not change that capture. The returned bounds are fitted onto the captured surface plane. Runtime tracking, component interaction and spatial anchors run locally.

Generated shape and hidden details remain approximate. Search retains actual web-tool source URLs, labels exact versus similar matches, and cannot verify exact internals from a similar product. Rebuild retains the object identity and original/current poses. Solid material colors from the generated component data are the default. Selection adds a subtle highlight without replacing the base color. Color accuracy is limited by the supplied image and generated model; it is not a recovered photographic texture. Optional hologram styling remains available through an explicit voice command.

The agent receives sampled camera frames when a tool requests them, not a continuous video stream. This is a stationary world anchor, not tracking of a physical object someone moves. Search-assisted generation took about 145 seconds in one real API probe; latency varies.

## Persistence and acceptance

Each object has a locally saved Meta spatial anchor and serialized geometry/state. Restoring waits for anchor localization before binding/rendering. Full headset POV, pointing accuracy, voice, visual alignment and leave/reenter persistence must be verified on the physical headset. A successful APK build alone does not establish those results.

Acceptance: reconstruct one object; walk around it; select/explode and explain a part; pull/return; rebuild the same object; add a second object; restart and relocalize; leave/return. Confirm source labels, geometry placement, no accidental regeneration of saved objects and truthful errors when camera/depth/network is unavailable.

See [configuration attribution](NOTICE.md) and [verification](../docs/VERIFICATION.md).

## Software verification

The Android APK built successfully. Seventeen shared backend tests and six iPhone tests passed. `GeometryChecks.Run` checks a supplied generated assembly, mesh indices/finite vertices, captured-ray orientation and Return pose in the Unity editor; set `SPATIAL_TEST_ASSEMBLY` to the probe JSON before invoking it. The real eleven-part / 37-primitive response passed. These checks do not measure headset calibration or visual fidelity.


## Concurrent reconstruction and guided explanations

Up to four independent reconstructions/refinements can run at once. Each keeps its own frozen capture, target pose, request ID and progress marker. Finishing another job does not steal the current selection or held object. Y cancels all pending jobs. Cancellation epochs reject delayed results and captures. Trigger selection still requires explicit scan confirmation or an explicit voice request.

New models include the visible exterior plus useful functional internals for that object category. Hidden geometry is labeled inferred unless exact-model documentation supports it. Housing panels are separate so the voice harness can reveal internals. Existing saved models remain readable; asking for missing internal components can refine the existing model while retaining its exterior and anchor.

Say “How does this work?” for a guided walkthrough, or “Explain the processor” for a specific component. The harness pulls out and highlights one part, explains its function and connections, and waits for the headset audio playback boundary before advancing. Speaking pauses the tour. It can also open/close housing, explode/assemble, return a part, or move/rotate/scale a named component. Right-stick click on a generated selection returns the complete model to its original anchor, resets part transforms and closes the housing. Stale commands are rejected after a newer user selection or Return.

This revision was reviewed through source inspection and compilation only. No new remote camera inspection, voice question, scan, manipulation or runtime tests were performed; the wearer owns all acceptance testing. Current scene records are preserved through the single final installation.
