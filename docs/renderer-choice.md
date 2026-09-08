# Renderer choice and local neural inference

2026-09-08 · Research and recommendation. RealityKit is implemented and native simulator/device builds pass. The signed iPad app runs its camera view; sustained frame rate, thermal behavior, and a controlled comparison with Three.js remain unmeasured.

## Decision

Keep **Swift + ARKit + RealityKit in one universal iPhone/iPad app**. Three.js is a good candidate for an optional browser scene inspector or a later Quest web client. Do not add either to the first device milestone unless it demonstrably shortens that work. Pointing perception is required for the demo; separate Neural Engine optimization remains optional.

This decision follows the desired interaction: continuous voice, newly generated editable geometry, physical placement, pointing and correction on supported iPhones and iPads. See [device strategy](devices.md).

## What “quicker” means

| Goal | Recommendation and limit |
| --- | --- |
| First generated 3D scene in a browser | Three.js probably shortens iteration and inspection; this is a development judgment, not a timing result |
| First complete iPhone/iPad AR loop | Native ARKit/RealityKit gives the direct platform integration |
| Faster Astra generation | Renderer choice alone does not reduce model latency; both can consume the same compact proposals |
| Faster frames or mesh installation | Unmeasured; compare equivalent content on the target device before claiming a winner |
| Shareable inspection of generated content | A small Three.js adapter can read saved normalized JSON and replay scene operations |
| Quest later | Evaluate Three.js/WebXR alongside Unity/OpenXR when the target experience is defined |

Three.js does not require the model to author renderer-specific JavaScript. Astra can use the same structured or hosted programmatic authoring path with either runtime. Keep the [scene format](data-formats.md) independent of renderer objects.

## The iPhone browser boundary

Three.js's standard AR entry point depends on browser WebXR `immersive-ar` support. A WebKit maintainer explicitly stated in March 2026 that WebXR is unsupported on iOS. Rendering ordinary 3D in a browser is a different capability from obtaining the tracked immersive AR session this application needs. [Three.js ARButton](https://threejs.org/docs/pages/ARButton.html), [WebKit maintainer response](https://bugs.webkit.org/show_bug.cgi?id=309550#c2).

There is a current nuance: Safari 27 beta introduces inline HTML `<model>` on iPhone/iPad. Apple's WWDC26 instructions still use AR Quick Look for placing those assets in the physical environment on those devices; immersive website features are described for visionOS. Inline 3D, Quick Look and application-owned continuous AR editing are different integration paths. [Safari 27 beta](https://webkit.org/blog/17967/news-from-wwdc26-webkit-in-safari-27-beta/), [WWDC26 model element session](https://developer.apple.com/videos/play/wwdc2026/215/).

Quick Look can present authored behaviors and animations; it is not merely a static screenshot. However, its documented integration is not an arbitrary Three.js scene executor accepting our live add/remove/replace-geometry stream alongside our custom voice lifecycle. It is a poor match for this first product loop. [Apple Quick Look integration](https://developer.apple.com/documentation/ARKit/previewing-a-model-with-ar-quick-look).

A native ARKit/Three.js bridge is possible in principle, as are other web tracking approaches. They introduce camera/tracking/compositing, synchronization and lifecycle responsibilities that need their own proof. A WKWebView wrapper does not automatically provide WebXR support. For this universal iPhone/iPad app, there is no established speed benefit from taking on that integration.

RealityKit is selected for its fit with native AR, not a claim that it always outperforms Three.js. Measure scene complexity, resource creation, frame time, audio stability and first-visible latency. Either renderer can perform poorly with excessive geometry or unbounded insertion.

## Where the Neural Engine fits

| Work | Execution in the proposed design |
| --- | --- |
| Astra reasoning and scene authoring | OpenAI cloud inference |
| Recipe validation and ordinary tessellation | Native CPU code; consider GPU computation only after profiling |
| Frame rendering | Device GPU through RealityKit/Metal |
| Required pointing perception | Vision hand detection; verify responsiveness on the demo device |

The Neural Engine is a neural inference accelerator, not a general replacement for mesh builders or the renderer. It does not speed up Astra inference running remotely. Core ML can use CPU, GPU and Neural Engine depending on the model and configuration. [Apple Core ML deployment](https://developer.apple.com/videos/play/wwdc2024/10161/).

The required demo interaction is **point-and-ask**: detect a hand in camera frames, map its fingertip into the displayed viewport, locally hit-test that screen point against the virtual scene, highlight the selected component, and pass its stable ID with the spoken request to Astra. Arav selected this screen-aligned baseline; two-dimensional landmarks do not establish full three-dimensional hand tracking or a physical pointing ray. [Vision hand pose](https://developer.apple.com/documentation/vision/detecthumanhandposerequest), [RealityKit screen-point selection](https://developer.apple.com/documentation/realitykit/arview/entity%28at%3A%29).

Arav clarified that pointing is required for the demo, even if it follows the first voice/generation slice. The [pointing plan](gestures.md) specifies targeting, failure behavior, and optional pinch/manipulation extensions.

Tap or reticle selection is a simpler implementation baseline and remains a fallback; it does not fulfill pointing acceptance. Camera perception identifies the real hand, not generated parts whose IDs we already know. Raw camera frames do not contain the virtual rack; recognizing our rendered objects again with another model would duplicate exact scene information.

Calling Vision does not prove our work used the Neural Engine. For a custom Core ML model, `.all` permits all compute units; `.cpuAndNeuralEngine` excludes the GPU while allowing CPU and Neural Engine. Neither promises exclusively Neural Engine execution or faster results. Inspect compute planning and profile the running app before making a hardware claim. [Compute configuration](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine), [Core ML and Neural Engine Instruments](https://developer.apple.com/videos/play/wwdc2022/10027/).

A local gesture classifier, real-component detector, or speech activity model may be useful later. Add one only for a measured input/perception problem. Bound prediction queues and drop obsolete camera frames; compare selection reliability, inference time, frame time and thermal behavior against the simpler baseline.

## Technicality evidence

Our strongest planned evidence is a working model-to-scene compiler and conversation loop: generate unfamiliar editable geometry, revise selected parts, interrupt obsolete generation correctly, align speech with accepted state, and reopen saved results without another model call. A second content pack tests whether the framework generalizes.

A local neural feature can strengthen that evidence if it improves interaction and has measured device execution. Merely listing Neural Engine, Metal or another framework does not establish a technical contribution. This is our recommendation for demonstrating engineering depth, not a prediction of judges' scores.
