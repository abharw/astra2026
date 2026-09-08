# astra2026

Spatial Assembly turns a selected iPhone or Quest 3 camera view into an editable, approximate 3D assembly placed in AR. GPT-6 Astra generates component descriptions and bounded geometry; OpenAI Realtime provides voice tools; ARKit/RealityKit on iPhone and Unity/OpenXR on Quest handle local tracking, rendering and interaction.

This is the **Akeil** development branch. `main` contains the requested initial README commit. Work done before repository creation is documented retrospectively, without backdating commits.

## What works

- Capture a pointed-at or tapped real object on an AR-capable iPhone.
- Research actual or similar technical references, then generate component primitives and bounded custom meshes using `gpt-6-astra` through a Mac bridge.
- Rebuild the active model using a correction and reference search while retaining its anchored pose.
- Explain selected components using their evidence labels and cited references.
- Use voice through `gpt-realtime-2.1`, or native buttons, to manipulate the generated assembly.
- Show inferred parts distinctly, explode/reassemble around the source pose, pull out a model, and return it to its original transform.
- Keep multiple generated objects in a place.
- Automatically save mapped places and object states on the iPhone.
- Attempt saved-map relocalization on reopening and restore models locally, without generating them again.

The physical phone saved a six-part speaker, then restored and autosaved the same room after app termination/relaunch. Four persistence tests and eight backend validation tests passed. This proves a same-location reopen, not guaranteed recognition after traveling elsewhere or precise visual registration to an object.

## Start here

- [Phone computer-use experiment](docs/PHONE_COMPUTER_USE.md)
- [Development journal: how we assembled this](docs/BUILD_JOURNAL.md)
- [Video-to-floor-plan experiment](docs/VIDEO_FLOOR_PLAN_EXPERIMENT.md)
- [Astra computer-use and evidence workflow](docs/ASTRA_PROCESS_LOG.md)
- [Airbnb photo comparison and video tour-data preparation](docs/PHOTO_AND_TOUR_EXPERIMENT.md)
- [Architecture and file walkthrough](docs/ARCHITECTURE.md)
- [Verification and remaining acceptance checks](docs/VERIFICATION.md)
- [Known limitations and next steps](docs/NEXT_STEPS.md)
- [Quest setup and controls](quest/README.md)
- [Native setup and usage](spatial-assembly/README.md)
- [Original browser prototype](browser-prototype/README.md)
- [Repository import and privacy notes](docs/IMPORT_NOTES.md)

## Run the native app

You need Xcode, XcodeGen, Node.js, Python 3, a physical AR-capable iPhone, and API access to the named models. LiDAR improves placement. Keep the Mac bridge and an HTTPS tunnel running.

```sh
cd spatial-assembly/server
npm ci
npm test
cd ..
# Start an HTTPS tunnel to localhost:8796 in another terminal.
python3 configure.py https://YOUR-TUNNEL-HOST
python3 server/launch.py
```

Enter the OpenAI key at the hidden prompt. In another terminal, set your Apple signing team in `spatial-assembly/ios/project.yml`, then generate/open the project:

```sh
cd spatial-assembly
xcodegen generate --spec ios/project.yml
open ios/SpatialAssembly.xcodeproj
```

Build to the iPhone. Move it slowly until tracking is ready, tap an object, then choose **Reconstruct that**. Wait for **Saved on this iPhone** before leaving. Open **Your places** to retry a saved location or start a new one.

No credentials, camera captures, or room maps are committed. Room recognition depends on seeing familiar surroundings. Geometry is approximate; hidden parts are inferred. Continuous tracking of a moved physical object is not implemented.

## Quest POV and reference-assisted reconstruction

The Quest client implements hand/controller pointing, real passthrough camera capture, environment-depth targeting, spatial anchors, part selection, explanations, rebuild and Realtime voice. Source-assisted research and voice have passed real API probes. Headset runtime acceptance is pending USB connection; do not interpret implementation or compilation as an observed headset result.

The source-photo probe returned 11 parts, 37 primitives including 2 custom meshes, and three similar-product manufacturer references. The photograph did not establish an exact model. This is approximate generated geometry, not a high-fidelity CAD scan. See the verification record for the boundaries of the evidence.

- [Best-fit spatial workflow](docs/SPATIAL_WORKFLOW.md) and [two additional tour tests](docs/SPATIAL_BEST_FIT_TESTS.md).
