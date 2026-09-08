# astra2026

Spatial Assembly turns a selected iPhone camera view into an editable, approximate 3D assembly placed in AR. GPT-6 Astra generates component descriptions and bounded geometry; OpenAI Realtime provides voice tools; ARKit and RealityKit handle local tracking, rendering and interaction.

This is the **Akeil** development branch. `main` contains the requested initial README commit. Work done before repository creation is documented retrospectively, without backdating commits.

## What works

- Capture a pointed-at or tapped real object on an AR-capable iPhone.
- Generate component geometry using `gpt-6-astra` through a Mac bridge.
- Use voice through `gpt-realtime-2.1`, or native buttons, to manipulate the generated assembly.
- Show inferred parts distinctly, explode/reassemble around the source pose, pull out a model, and return it to its original transform.
- Keep multiple generated objects in a place.
- Automatically save mapped places and object states on the iPhone.
- Attempt saved-map relocalization on reopening and restore models locally, without generating them again.

The physical phone saved a six-part speaker, then restored and autosaved the same room after app termination/relaunch. Four persistence tests and eight backend validation tests passed. This proves a same-location reopen, not guaranteed recognition after traveling elsewhere or precise visual registration to an object.

## Rack Lab hardware library

The [complete rack library](datacenter-rack/README.md) adds a pregenerated, editable server rack with demand-loaded mechanical parts, motherboard, memory and processor study. [Agents start here](datacenter-rack/docs/AGENT_USAGE.md); fetch binaries with `git lfs pull`.

## Start here

- [Development journal: how we assembled this](docs/BUILD_JOURNAL.md)
- [Video-to-floor-plan experiment](docs/VIDEO_FLOOR_PLAN_EXPERIMENT.md)
- [Architecture and file walkthrough](docs/ARCHITECTURE.md)
- [Verification and remaining acceptance checks](docs/VERIFICATION.md)
- [Known limitations and next steps](docs/NEXT_STEPS.md)
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
