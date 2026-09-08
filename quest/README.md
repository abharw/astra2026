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

The panel follows at eye height by default. Grabbing and releasing pins it in the room; left thumbstick click resumes following. See [live headset and casting test record](../docs/QUEST_LIVE_TESTING.md).

- Hold trigger/pinch on the panel header to move it, or hold the right grip while aiming anywhere on the panel. Release to place it. While moving, the right stick adjusts its distance. Click the left thumbstick to bring the panel back in front of you.
- The panel shows Ready, Listening, Speaking, Reconstructing, Starting voice, Camera not ready or Offline, with elapsed generation time and the next action. Start/Stop voice and Pull/Return labels reflect current state.
- Point the right controller or tracked right hand at a real surface; trigger/pinch captures it.
- Trigger/pinch a generated component to select and toggle explosion.
- **A** toggles explode/assemble. **B** toggles voice. **X** explains the next part. **Y** researches and rebuilds the active object.
- Floating buttons provide Reconstruct, Pull/Return, Explain, Voice, Rebuild, Cancel, Restore and Reconnect.
- After Pull, the right thumbstick moves forward/back and rotates. Return restores the saved source pose.
- Say “reconstruct that,” “explain this part,” “find a schematic and improve the bracket,” or “what am I looking at?” Voice tools request fresh frames when needed.

## What the headset measures

The pointing ray intersects Meta environment depth. The target is projected into the physical camera image using the image-associated camera pose and calibrated API projection. Capture freezes the target, normal, pose and corner rays; later head movement does not change that capture. The returned bounds are fitted onto the captured surface plane. Runtime tracking, component interaction and spatial anchors run locally.

Generated shape and hidden details remain approximate. Search retains actual web-tool source URLs, labels exact versus similar matches, and cannot verify exact internals from a similar product. Rebuild retains the object identity and original/current poses. Color-coded “hologram” styling currently uses opaque material; optical see-through is not implemented.

The agent receives sampled camera frames when a tool requests them, not a continuous video stream. This is a stationary world anchor, not tracking of a physical object someone moves. Search-assisted generation took about 145 seconds in one real API probe; latency varies.

## Persistence and acceptance

Each object has a locally saved Meta spatial anchor and serialized geometry/state. Restoring waits for anchor localization before binding/rendering. Full headset POV, pointing accuracy, voice, visual alignment and leave/reenter persistence must be verified on the physical headset. A successful APK build alone does not establish those results.

Acceptance: reconstruct one object; walk around it; select/explode and explain a part; pull/return; rebuild the same object; add a second object; restart and relocalize; leave/return. Confirm source labels, geometry placement, no accidental regeneration of saved objects and truthful errors when camera/depth/network is unavailable.

See [configuration attribution](NOTICE.md) and [verification](../docs/VERIFICATION.md).

## Software verification

The Android APK built successfully. Seventeen shared backend tests and six iPhone tests passed. `GeometryChecks.Run` checks a supplied generated assembly, mesh indices/finite vertices, captured-ray orientation and Return pose in the Unity editor; set `SPATIAL_TEST_ASSEMBLY` to the probe JSON before invoking it. The real eleven-part / 37-primitive response passed. These checks do not measure headset calibration or visual fidelity.
