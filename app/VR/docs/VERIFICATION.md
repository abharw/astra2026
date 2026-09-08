# Verification record

## Observed results

| Check | Result | What it establishes |
|---|---|---|
| Browser interaction after effect cleanup fix | Passed during development | Authored orbit/select/explode controls worked |
| Physical iPhone build/install/launch | Passed | Native app runs on the connected device |
| Live camera tracking and bridge connection | Observed | Initial phone camera and network path worked |
| Real GPT-6 source-photo probe | Eight parts returned | Actual image-to-schema API path |
| Real phone captures | Laptop and speaker assemblies returned | Phone images reached GPT-6 and produced geometry |
| Realtime probe | Explode tool call plus audio | Realtime tool/audio API path |
| Backend tests | 17 passed | Geometry/command validation, source grounding, pipeline/refinement, cancellation and restored scene context |
| iPhone XCTest suite | 6 passed | Storage/state round trip, invalid-data handling, backward decoding and mesh indices |
| Same-location terminate/relaunch | Restored and autosaved same room | Persistence and ARKit-gated restoration path ran on phone |
| Before/after saved-state comparison | IDs/geometry/state preserved; matrix delta ~7e-7 | Saved object state survived restart |

The original source-photo result took roughly 45 seconds. Individual phone generations took roughly 32–67 seconds. These timings are samples, not performance promises.

## Reproduce tests

Backend:

```sh
cd spatial-assembly/server
npm ci
npm test
```

iOS unit tests after generating the Xcode project:

```sh
cd spatial-assembly
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/SpatialAssembly.xcodeproj -scheme SpatialAssembly \
  -destination 'platform=iOS Simulator,name=YOUR_AVAILABLE_SIMULATOR' test
```

Use an available Simulator name on your machine. Unit tests do not test real camera relocalization.

## Physical acceptance procedure

1. In a textured, well-lit room, create an object and wait for **Saved on this iPhone**.
2. Create a second object. Verify the first remains and tapping either selects it.
3. Explode one object and pull the other away from home. Wait for a save.
4. Close and reopen. Look at the same surroundings. Verify both models and their individual states restore.
5. Use Return and confirm the original pose is recovered.
6. Leave for another room. Reopen: previous models must not appear in unrelated coordinates. Create an object there and wait for saving.
7. Return to the first room and verify recognition, using Your places to retry if necessary.
8. Repeat under changed lighting and temporary occlusion. When recognition fails, the app must report/search rather than silently treating the room as matched.

Only the single-object same-location reopen and saved-state comparison have been completed on the physical phone. The full multirooom visual sequence above remains open.

## Evidence handling

`spatial-assembly/persistence-verification.json` contains sanitized comparison results. Raw world maps, camera images, API response identifiers, device identifiers, tunnel tokens and the OpenAI key are not included. Matching serialized transforms does not measure visual registration error or tracking drift.

## Reference and Quest extension

- Actual web-search/API probe: three manufacturer references returned, all similar rather than exact; eleven parts, 37 primitives and two custom meshes. Search about 35 seconds, whole generation about 145 seconds. Source photograph and full raw response stay private.
- Actual Realtime API probe: selected grille explanation plus audio, with exact-model uncertainty stated. Device selection was a probe acknowledgment, not headset interaction.
- Updated research-enabled iPhone app built, installed and launched. Full physical reference/rebuild visual acceptance remains open.
- Quest Android APK built successfully. The APK manifest contains network, audio, hand tracking, scene, anchor and headset-camera permissions. Unity geometry checks accepted the real eleven-part / 37-primitive response and checked captured-ray orientation and return pose. Headset runtime has not been verified.

To reproduce the live source-photo probe, use `node server/live-research-probe.mjs /path/to/speaker.jpeg` from spatial-assembly. It sends the supplied image to the bridge and uses a speaker-specific prompt/target; adapt those for a different photograph. Then `node server/live-voice-probe.mjs` uses the saved probe assembly. `BRIDGE_WS` overrides the default localhost:8796 WebSocket endpoint. These are API smoke probes, not end-to-end device tests.
