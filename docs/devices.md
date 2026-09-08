# iPhone and iPad support

2026-09-08 · Proposed device strategy. Arav identified his iPad as an **iPad Air M4 running iPadOS 26.5**. A read-only developer-device check currently sees his paired iPhone 15 Pro as available and no paired iPad. The iPad model/OS is user-reported; app deployment and runtime behavior on it remain untested.

## One application, two device families

Build one universal native app targeting supported iPhones and iPads, using the same Swift SDK, ARKit/RealityKit renderer, Vision input processing, scene contract, backend and voice integration. RealityKit's AR camera mode supports both device families. [Apple AR camera mode](https://developer.apple.com/documentation/realitykit/arview/cameramode-swift.enum/ar).

Use the **iPad Air M4 on iPadOS 26.5 as the primary demo target**, with the iPhone 15 Pro as the second test device. The iPhone can host the first hardware spike while the iPad is being connected. The iPad preference reflects the pointing setup and shared screen, not a measured renderer or inference speed advantage.

| Device | Role | Current evidence |
| --- | --- | --- |
| Arav's iPad Air M4, iPadOS 26.5 | Primary pointing/voice/AR demo | Model and OS reported by Arav; not yet paired or tested here |
| Arav's iPhone 15 Pro | Secondary device and available first spike | Developer tooling reports available/paired; app behavior untested |

Configure both device families in the app target. Adapt controls to the viewport and safe areas, keep the rendered scene's physical scale in metres, and derive image-to-view mapping from the actual AR viewport. Do not hardcode a phone aspect ratio. Orientation changes, window resizing, app interruptions and resume must invalidate stale pointing observations and cancel any manipulation preview. One active AR scene/session per app is sufficient; multiwindow collaboration is outside this milestone.

Keep the chosen APIs compatible with iPadOS 26.5; the demo must not depend on iPadOS 27 beta features. Pin the universal deployment target after confirming the secondary phone's OS. Check `ARWorldTrackingConfiguration.isSupported`, availability of the chosen Vision API, and any optional AR features at runtime. Broad historical ARKit compatibility is not a promise that every older iPad can run this application's selected APIs and workload. [Apple device checks](https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission).

## Pointing setup

A teammate holding a landscape iPad beside Arav can free his hands while keeping the display visible to him. His pointing hand must enter the rear-camera image. Test whether both people can see the highlighted part, whether the holder can keep the view steady, and whether the microphone clearly captures Arav while the app speaks.

The virtual rack is visible through the device display. A presenter facing the rear of the tablet cannot see it directly in the room. Do not assume a two-person arrangement solves this; place the screen where the presenter can use its feedback or provide a mirrored view.

Arav selected screen-aligned pointing first: map a fingertip's image position into a screen-space hit test. iPad does not turn those two-dimensional observations into a physical pointing direction. Full three-dimensional pointing is outside the initial requirement. [Pointing contract](gestures.md).

## Neural Engine and LiDAR

Arav's **iPad Air M4 has a 16-core Neural Engine**. Apple's specifications also list the M4 CPU and GPU; those are separate execution resources. This is an appropriate hardware target for the proposed native AR/hand-detection experiment, with sustained performance still to measure. [Apple iPad Air M4 specifications](https://support.apple.com/en-ie/126471).

Neural Engine optimization is not a separate acceptance requirement. Start with Apple's Vision hand-pose detector and measure pointing responsiveness alongside AR and voice. This still uses machine learning; the decision is to avoid a custom hardware optimization project before identifying a bottleneck. If a custom Core ML model becomes useful, its compute-unit configuration permits hardware choices without guaranteeing exclusive Neural Engine execution or a speedup. [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits).

No LiDAR is required by our baseline pointing recipe: it uses camera landmarks and known virtual geometry. Optional scene depth has separate hardware support and must be checked; depth availability by itself does not establish accurate three-dimensional fingers. [ARKit scene-depth support](https://developer.apple.com/documentation/arkit/arconfiguration/supportsframesemantics%28_%3A%29).

Choose the demo device by measured selection reliability, camera framing, voice quality, frame time and ergonomics. Track actual Neural Engine use only if profiling is needed or we intend to make a hardware-specific technical claim.
