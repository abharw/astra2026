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
| Backend validation tests | 8 passed | Bounded geometry and enumerated command validation |
| Persistence XCTest suite | 4 passed | Storage, state round trip and invalid-data handling |
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
