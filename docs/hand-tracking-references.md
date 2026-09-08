# Hand-tracking implementation references

**Research status:** source review on 2026-09-08. No example below was built,
run, or device-tested as part of this review. The intended first target is an
iPad AR experience using the rear ARKit camera, Vision's 2D hand landmarks,
and a RealityKit viewport hit test. That is a different platform and input
model from visionOS hand anchors.

## What can run on iPad
### Apple: Detecting Hand Poses with Vision

- **Source:** [Apple sample documentation and download](https://developer.apple.com/documentation/vision/detecting-hand-poses-with-vision)
- **What it demonstrates:** a virtual drawing app that obtains hand landmarks
  through `VNDetectHumanHandPoseRequest` from a live camera feed.
- **Platform/input:** iOS/iPadOS Vision, 2D camera-image landmarks. It is a
  freehand/drawing sample, not an ARKit or RealityKit sample.
- **License:** Apple Sample Code License; preserve the downloaded sample's
  license notice if copying source.
- **Review age:** published with WWDC20 (2020); Apple documentation was
  available at review time.
- **Use here:** canonical reference for the Vision request, landmark confidence
  filtering, and camera-to-display coordinate conversion. The project uses a
  camera preview, so its point mapping cannot be copied verbatim into `ARView`.

### john-rocky/RealityKit-Sampler: HandInteractionARViewController

- **Source:** [controller](https://github.com/john-rocky/RealityKit-Sampler/blob/main/RealityKitSampler/UIKitViews/HandInteractionARViewController.swift),
  [repository license](https://github.com/john-rocky/RealityKit-Sampler/blob/main/LICENSE)
- **What it actually does:** creates an `ARView` with a world-tracking session,
  obtains `ARFrame.capturedImage` in `ARSessionDelegate.session(_:didUpdate:)`,
  runs `VNDetectHumanHandPoseRequest`, reads `.indexTip`, then calls
  `arView.entity(at:)`. When the hit entity is its box, it applies an upward
  force. It also configures collision shapes for the target.
- **Platform/input:** iOS/iPadOS ARKit + RealityKit + Vision. This is the most
  direct open-source reference for the intended index-tip-to-RealityKit-hit
  vertical slice.
- **License:** MIT, copyright 2021 MLBoy.
- **Review age/status:** controller dated 2021-07-09; source read, not built or
  independently verified on current iPadOS.
- **Do not copy unchanged:** it starts a global Vision task for every AR frame,
  has no in-flight/serial gate, sets orientation to `.up`, and maps using
  `CGPoint(x: tip.location.y, y: tip.location.x)`. That axis swap is an
  experiment-specific conversion, not a general ARView mapping rule.

### r4ghu/iOS-Vision-HandPose

- **Source:** [camera controller](https://github.com/r4ghu/iOS-Vision-HandPose/blob/master/iOS-Vision-HandPose/CameraViewController.swift),
  [repository](https://github.com/r4ghu/iOS-Vision-HandPose)
- **What it actually does:** front-camera iOS hand-pose visualization, derived
  from Apple's hand-pose sample. It selects one hand, discards late video
  frames, filters landmarks at confidence `0.3`, flips Vision's Y coordinate,
  then uses `AVCaptureVideoPreviewLayer` to convert into UIKit coordinates.
- **Platform/input:** iOS Vision camera preview only; no ARKit, RealityKit, or
  entity selection.
- **License:** repository MIT. Its Apple-derived source header also refers to
  the original sample's license; retain applicable notices when reusing code.
- **Review age/status:** README targets iOS 14/Xcode 12 and reports about 5 FPS;
  source read, not built or independently verified on current iPadOS.
- **Use here:** a practical reference for confidence gates and the fact that
  Vision coordinates need an explicit transform. Its front-camera preview
  mapping is not the mapping for a rear-camera AR session.

### moutend/HandPoseRhythmMachine

- **Source:** [repository](https://github.com/moutend/HandPoseRhythmMachine),
  [license](https://github.com/moutend/HandPoseRhythmMachine/blob/main/LICENSE)
- **What it actually does:** an iOS 15+ demo that recognizes rock/paper hand
  shapes with Vision and triggers sound effects.
- **Platform/input:** iOS Vision, semantic freehand gesture recognition; no
  ARKit/RealityKit rendering or hit testing.
- **License:** MIT for Swift source; repository README separately identifies
  the provenance of audio assets.
- **Review age/status:** 2024 copyright, small two-commit repository; source
  and README reviewed, not run.
- **Use here:** gesture classification should be a stateful semantic layer over
  raw landmarks, rather than a single-frame action trigger.

## Apple ARKit pipeline guidance
[Tracking and altering images](https://developer.apple.com/documentation/arkit/tracking-and-altering-images)
is not a hand sample, but is Apple’s directly relevant `ARFrame.capturedImage`
plus Vision reference. It recommends checking camera images at most about 10
times per second and running requests serially with an `isBusy` guard. Treat
that as the baseline for the iPad pipeline, rather than dispatching work from
every `ARSession` frame as the 2021 sampler does.

The Vision API is [`VNDetectHumanHandPoseRequest`](https://developer.apple.com/documentation/vision/vndetecthumanhandposerequest).
It returns 2D observations and confidence values; it does not supply a tracked
3D hand skeleton or a system pinch gesture on iPad.

## Valid shared iPad pipeline
1. ARKit supplies the rear-camera frames and tracking; RealityKit renders the scene in `ARView`.
2. A bounded, single-in-flight Vision worker consumes selected
   `ARFrame.capturedImage` frames and requests one hand initially.
3. It accepts index-tip output only above a chosen confidence threshold, then
   applies a tested camera-orientation and viewport transform.
4. It feeds that resulting **2D ARView point** to `entity(at:)`; targets need
   collision shapes. This is a viewport hit, not a 3D finger contact.
5. A later pinch recognizer requires confident thumb and index tips, a
   hand-scale-normalized distance, hysteresis, and debounce/dwell before it
   issues an action.

The transform is a product acceptance boundary: place known target entities at
multiple visible viewport positions and verify that the displayed index marker
and selected entity agree in every supported iPad orientation. Do not assume a
portrait-only `x/y` swap, raw image dimensions, or a front-camera mirror rule.

### Our SDK and coordinate choice

The installed Xcode 26.6 iPhoneOS 26.5 SDK marks RealityKit's hand anchor
capability and `AnchoringComponent.Target.hand` unavailable on iOS. The SDK's
`ARFrame.h` exposes `displayTransformForOrientation:viewportSize:`; newer web
documentation for `viewRotationAngle` is not available in this toolchain.
Keep `displayTransform(for:viewportSize:)` with the actual window-scene orientation.

Our adapter passes `.up` to Vision, keeping its output in raw camera-image
coordinates, then flips Y and applies the frame's display transform. Apple's
[WWDC21 hand-pose session](https://developer.apple.com/videos/play/wwdc2021/10039/)
also demonstrates a raw `ARFrame.capturedImage` handler. This is coherent mapping,
but does not prove equally reliable detection with an upside-down sensor image.
Test both landscape directions and portrait on hardware. If orientation-aware
Vision input becomes necessary, invert that orientation back into raw-frame
coordinates before applying ARKit's transform; changing only the handler's
orientation would misalign the cursor.

## visionOS references: useful ideas, incompatible implementation
### Apple: Discover RealityKit APIs for iOS, macOS, and visionOS (WWDC24)

- **Source:** [session 10103](https://developer.apple.com/videos/play/wwdc2024/10103/)
- **What it demonstrates:** `SpatialTrackingSession` and RealityKit hand anchor
  entities; thumb/index distance controls a spaceship’s throttle and hand pose
  controls its orientation.
- **Status:** official visionOS sample material, reviewed but not run.
- **Why it is not an iPad implementation:** it relies on Apple Vision Pro’s
  platform hand-tracking data and spatial hand anchors, which ARKit on iPad
  does not expose.

### robomex/visionOS-2-Object-Tracking-Demo

- **Source:** [repository](https://github.com/robomex/visionOS-2-Object-Tracking-Demo)
- **What it demonstrates:** a visionOS 2 object-tracking experiment whose
  virtual highlights respond to hand proximity; it combines object tracking
  with `HandTrackingProvider`.
- **Status/license:** public source, license file present; reviewed as a
  visionOS-only design reference, not run. Confirm the repository license text
  before source reuse.
- **Why it is not an iPad implementation:** `HandTrackingProvider` is a
  visionOS ARKit provider, not the iOS/iPadOS Vision camera-landmark pipeline.

### AlohaYos/VisionGesture

- **Source:** [repository](https://github.com/AlohaYos/VisionGesture),
  [MIT license](https://github.com/AlohaYos/VisionGesture/blob/main/LICENSE)
- **What it demonstrates:** gesture-state templates over visionOS hand joints;
  it also includes a sender that estimates 2D poses with Vision for simulator
  development.
- **Status:** repository reviewed, not run; last described project activity is
  from the visionOS 1/2024 era.
- **Why it is not an iPad implementation:** its receiver and real interaction
  model are Apple Vision Pro hand tracking. The iPhone/iPad sender is a test
  bridge, not an iPad AR interaction implementation.

## Non-claims

This document does not claim that these apps work on iPad Air M4 or iPadOS
26.5, that their coordinate transforms are correct for this app, or that an
index-tip viewport hit provides physical contact. Each statement above is
limited to inspected source or the linked primary documentation.
