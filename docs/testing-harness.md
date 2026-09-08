# Development testing harness

2026-09-08 · Implemented a bounded replay diagnostic and a physical-device test plan with explicit evidence limits.

## Decision

Use three complementary lanes:

1. Run the universal app on the physical iPad Air M4 and iPhone for camera, Vision pointing, and ARKit behavior. Observe the iPad through AirPlay or QuickTime USB Screen input without starting a recording. Screen observation is evidence capture only; it does not give the Mac interactive control of iPadOS.
2. Run the universal app in iPad and iPhone simulators for layout, native scene compilation, the live backend/UI loop, accessibility, and screenshots.
3. Run `tools/PointingReplay` only as a headless synthetic-landmark replay over the product's shared viewport mapper and pointing resolver.

Do not route the Mac camera into Simulator and call the result an AR test. Apple's current AVCam documentation says Simulator has no access to device cameras. Apple's Xcode documentation also warns that hardware-specific features may be unavailable in Simulator and requires physical devices to verify those features. In the installed Xcode 26.6 toolchain, `simctl io` exposes screen enumeration, screen recording, and screenshots; it has no camera-input operation. The installed `simctl privacy` command also has no camera permission service.

The diagnostic is intentionally not a second camera or scene application. It catches deterministic coordinate, confidence, staleness, stability, hand-loss, and speech-lock regressions quickly. Only a physical supported iPhone/iPad run can establish Vision behavior on live device frames, ARKit world tracking, device camera behavior, viewpoint changes caused by moving the device, thermal behavior, or real-device end-to-end latency.

Primary sources:

- [Apple: AVCam, including Simulator camera limitation](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app)
- [Apple: Running on simulated or physical devices](https://developer.apple.com/documentation/Xcode/running-your-app-on-simulated-or-physical-devices)
- [Apple: Verify AR configuration support](https://developer.apple.com/documentation/arkit/arconfiguration/issupported)
- [Apple: Detecting hand poses with Vision](https://developer.apple.com/documentation/vision/detecting-hand-poses-with-vision)
- [Apple: Authorizing camera access](https://developer.apple.com/documentation/avfoundation/avcapturedevice)
- [Apple: Use AirPlay to stream an iPhone or iPad screen to a Mac](https://support.apple.com/en-gb/guide/mac-help/mchld7e543a0/mac)
- [Apple: iPhone Mirroring compatibility and interaction boundary](https://support.apple.com/en-ie/120421)

## What the replay diagnostic exercises

`tools/PointingReplay` is an XcodeGen command-line project. It feeds named normalized samples through `SpatialApple.PointingViewportTransform` and `SpatialApple.PointingResolver`, then emits a provenance-labeled JSON receipt.

It uses a deterministic two-region hit-test stub with stable semantic IDs. Therefore it proves resolver behavior for exact samples; it does not prove RealityKit entity picking. RealityKit picking and highlight feedback belong in the universal app's Simulator and device lanes.

The harness deliberately uses the package implementations owned by the product:

- `SpatialApple` owns viewport mapping, pointing resolution, and the real device Vision adapter.
- The replay executable owns only named synthetic cases, expected outcomes, and evidence serialization.

The diagnostic must not fork image-to-viewport math, smoothing, staleness, or selection resolution. A test that uses different algorithms than the app is only a lookalike.

## Run it

Generate, build, and run all cases:

```sh
cd tools/PointingReplay
xcodegen generate
xcodebuild \
  -project AstraPointingReplay.xcodeproj \
  -scheme AstraPointingReplay \
  -destination 'platform=macOS' \
  -derivedDataPath .derived-data \
  build
.derived-data/Build/Products/Debug/astra-pointing-replay \
  --all \
  --output pointing-replay.json
```

Run one case and write the receipt to standard output:

```sh
.derived-data/Build/Products/Debug/astra-pointing-replay \
  --case stable-target-lock
```

Every receipt declares `syntheticLandmarks` and explicitly excludes Vision, camera, ARKit, and physical-device claims. Built-in expected outcomes make the process exit unsuccessfully if a case regresses.

## Deterministic cases

These cases exercise the exact shared mapper and resolver without a camera prompt:

- **stable-target-lock:** several confident points remain over one selectable component, then speech begins and locks that stable `nodeId`.
- **low-confidence-loss:** a confident hover is followed by observations below the accepted confidence and must not produce a new lock.
- **stale-observation:** an old timestamp arrives after fresh input and must not retarget the cursor.
- **edge-sweep:** normalized image points sweep the image edges to expose orientation, crop, and vertical-axis mistakes.
- **target-boundary-jitter:** samples alternate across adjacent parts; the resolver must not invent a stable target before its configured stability condition is met.
- **loss-and-reacquire:** hand loss hides hover; a later confident sequence may establish a fresh hover while preserving a previously explicit selection according to the product contract.

Each test records expected and actual resolver states. Synthetic samples are useful because they isolate contract errors and are reproducible. They are not detector-accuracy evidence.

## Simulator lane

The installed destination used for the tablet layout is:

```text
iPad Air 11-inch (M4)
iOS 26.5
UDID 564C0D96-3E0F-491B-8592-910A7DAEECEA
```

The simulator automatically uses the non-AR surface. After installing and launching, tap Load rack; connect to the local service for live model tests. Named replay cases belong to the separate CLI, not app launch arguments. Capture output with:

```sh
xcrun simctl io 564C0D96-3E0F-491B-8592-910A7DAEECEA screenshot evidence/local/simulator-ipad-fixture.png
```

Simulator evidence must be labeled `iOSSimulator` and `nonAR`. It can establish that the universal app lays out correctly, installs the expected semantic scene, exposes stable accessibility identifiers, and responds to deterministic input. It cannot establish camera capture, ARKit tracking, physical placement, or real hand pointing.

## Evidence ladder

Keep evidence claims narrow and cumulative:

| Evidence | Allowed claim |
| --- | --- |
| Unit replay receipt | The shared pure mapper/resolver produced the recorded state transitions for the exact inputs |
| iPad Simulator screenshot/UI run | The iPad app's non-AR layout, scene runtime, and test hooks behaved in the recorded simulator/toolchain |
| Physical iPad capture plus application receipt | The real iPad camera, ARKit tracking, renderer, selection, and product loop behaved under the recorded conditions |

The physical-device acceptance run should bind its evidence to device model, OS/build, app commit, scene fixture/IDs, camera orientation, and monotonic timestamps. Record end-of-utterance to first acknowledgement, end-of-utterance to visible accepted scene change, pointing observation age at lock, wrong-target requests, hand-loss recovery, render frame behavior, and whether obsolete generated work was prevented from appearing.
