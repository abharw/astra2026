# iPhone and iPad support

2026-09-08 · `devicectl deviceinfo` verifies the wired **iPad Air 13-inch (M4)** (`iPad16,10`) on iPadOS 26.5. iPhone 15 Pro on iOS 26.6.1 is also verified and available. The iPad has Developer Mode enabled and its development profile trusted. A signed app has been installed and launched; its rear-camera view was inspected over USB in QuickTime. Arav reported that the updated fingertip ring tracks his hand and turns green over a part. Universal deployment floor is iOS/iPadOS 26. Accuracy across orientations and the combined voice interaction remain under test.

## One application, two device families

Build one universal native app targeting supported iPhones and iPads, using the same Swift SDK, ARKit/RealityKit renderer, Vision input processing, scene contract, backend and voice integration. RealityKit's AR camera mode supports both device families. [Apple AR camera mode](https://developer.apple.com/documentation/realitykit/arview/cameramode-swift.enum/ar).

Use the **iPad Air M4 on iPadOS 26.5 for the shared presentation**, and prioritize **iPhone usability for audience participation**. Arav requested phone optimization after the first successful iPad pointing trial. Both use the exact same camera/Vision/RealityKit implementation; phone work concerns compact controls, reachable touch targets, camera framing, and measured performance. The iPad preference reflects the shared screen, not a measured renderer or inference speed advantage.

| Device | Role | Current evidence |
| --- | --- | --- |
| iPad Air 13-inch (M4), iPadOS 26.5 | Shared presentation and first hardware test | Signed app/camera running; Arav confirmed fingertip tracking and green target feedback; combined voice trial pending |
| Arav's iPhone 15 Pro | Phone usability and audience experience reference | Universal build installed; signature/provisioning pass; Arav trusted its developer profile and the app launched. Controls reviewed in simulator portrait/landscape; full device trial pending |

Configure both device families in the app target. Adapt controls to the viewport and safe areas, keep the rendered scene's physical scale in metres, and derive image-to-view mapping from the actual AR viewport. Do not hardcode a phone aspect ratio. Orientation changes, window resizing, app interruptions and resume must invalidate stale pointing observations and cancel any manipulation preview. One active AR scene/session per app is sufficient; multiwindow collaboration is outside this milestone.

Keep the chosen APIs compatible with iPadOS 26.5; the demo must not depend on iPadOS 27 beta features. The universal deployment floor is iOS/iPadOS 26, below the verified secondary phone's OS. Check `ARWorldTrackingConfiguration.isSupported`, availability of the chosen Vision API, and any optional AR features at runtime. Broad historical ARKit compatibility is not a promise that every older iPad can run this application's selected APIs and workload. [Apple device checks](https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission).

## Pointing setup

A teammate holding a landscape iPad beside Arav can free his hands while keeping the display visible to him. His pointing hand must enter the rear-camera image. Test whether both people can see the highlighted part, whether the holder can keep the view steady, and whether the microphone clearly captures Arav while the app speaks.

The virtual rack is visible through the device display. A presenter facing the rear of the tablet cannot see it directly in the room. Do not assume a two-person arrangement solves this; place the screen where the presenter can use its feedback or provide a mirrored view.

Arav selected screen-aligned pointing first: map a fingertip's image position into a screen-space hit test. iPad does not turn those two-dimensional observations into a physical pointing direction. Full three-dimensional pointing is outside the initial requirement. [Pointing contract](gestures.md).

## Neural Engine and LiDAR

Arav's **iPad Air M4 has a 16-core Neural Engine**. Apple's specifications also list the M4 CPU and GPU; those are separate execution resources. This is an appropriate hardware target for the proposed native AR/hand-detection experiment, with sustained performance still to measure. [Apple iPad Air M4 specifications](https://support.apple.com/en-ie/126471).

Neural Engine optimization is not a separate acceptance requirement. Start with Apple's Vision hand-pose detector and measure pointing responsiveness alongside AR and voice. This still uses machine learning; the decision is to avoid a custom hardware optimization project before identifying a bottleneck. If a custom Core ML model becomes useful, its compute-unit configuration permits hardware choices without guaranteeing exclusive Neural Engine execution or a speedup. [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits).

No LiDAR is required by our baseline pointing recipe: it uses camera landmarks and known virtual geometry. Optional scene depth has separate hardware support and must be checked; depth availability by itself does not establish accurate three-dimensional fingers. [ARKit scene-depth support](https://developer.apple.com/documentation/arkit/arconfiguration/supportsframesemantics%28_%3A%29).

Choose the demo device by measured selection reliability, camera framing, voice quality, frame time and ergonomics. Track actual Neural Engine use only if profiling is needed or we intend to make a hardware-specific technical claim.
