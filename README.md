# Astra Spatial

A native spatial conversation experiment for the Cerebral Valley / OpenAI hackathon. Ask for an explanation or a useful 3D structure, then point at parts and keep talking. The starting example is a server rack; the framework itself works with generic geometry and semantic components.

**Astra authors scene descriptions in the cloud. Swift builds their meshes on the device. RealityKit renders them using the device GPU.** The model never sends executable Swift, GPU buffers, or SQL to the iPad. One Realtime conversation carries typed text and optional audio; its single forced `ask_astra` tool routes scene reasoning to Astra and returns a receipt-gated final text/audio response. There is no phrase-to-animation lookup in the model path.

## Read the project

- [Work handoff](HANDOFF.md): completed repository and image stages, followed by native flow geometry.
- [Generated illustrations](docs/images-2.5-integration-status.md): real Flare integration, native panels, measured latency and fidelity limits.
- [Architecture](docs/architecture.md): responsibilities, runtime loop, and future extension boundaries.
- [Product](docs/product.md): current interaction and accessibility constraints.
- [APPROACH](APPROACH.md): chronological Arav/Astra collaboration log.
- [Research](docs/research.md): original alternatives and hypotheses; it is background, not the current implementation contract.
- [Scene contract](framework/contract/README.md): exact data formats and acceptance rules, with [JSON Schema](framework/contract/scene.schema.json).
- [Codebase audit](docs/codebase-audit.md): what ships, what is test/evidence infrastructure, and deferred surfaces.
- [Backend endpoint](docs/backend-endpoint.md): the current authenticated remote development endpoint boundary.
- [Apple references](docs/apple-references.md): source study and implementation implications.
- [Hand-tracking references](docs/hand-tracking-references.md): Apple examples, real iOS apps, and platform/coordinate boundaries.
- [Testing](docs/testing-harness.md) and [live evidence](docs/evidence/README.md): what has actually been checked.

## Repository

The repository groups code and supporting material into app, backend, framework, assets, tools and docs. The [consolidation record](docs/repository-structure-plan.md) tracks migration acceptance; the table below describes the reorganized checkout.

| Path | Owns |
| --- | --- |
| `framework/Sources/SpatialCore` | Portable values, closed decoding, resource validation, canonical hashes, transactional scene reducer |
| `framework/Sources/SpatialApple` | RealityKit resources and hierarchy, device execution, selection, Vision pointing, SQLite checkpoints |
| `app` | Universal iPhone/iPad SwiftUI app, audio I/O, Realtime connection, user controls |
| `backend` | Astra Responses calls, normalized proposals, accepted-scene mirror, image jobs/artifacts, ephemeral voice credentials |
| `assets/server-rack` | Explicitly authored starting content, outside the framework |
| `assets/imported-rack` | Source-derived Blender assets, hierarchy templates, selection proxies and provenance |
| `tools/Sources/SceneLab` | Small Swift acceptance client using the production reducer |
| `tools/Sources/PointingReplay` | Small synthetic pointing replay; no camera app or duplicate renderer |
| `tools/assets`, `tools/checks`, `tools/dev-session.py` | Offline asset preparation, focused acceptance checks, and local development commands |
| `docs` | Architecture, product decisions, references, and dated evidence |
| `.local` | Ignored development credentials, logs, downloaded sources, and build output |

The app targets iOS/iPadOS 26. The primary device is an iPad Air 13-inch (M4) on iPadOS 26.5. Xcode 26.6 and Swift 6.3.3 were used here. Quest is a future renderer adapter, not an implemented target.

The Apple package separates `Rendering`, `Input`, `Transport`, `Storage`, `Illustrations`, and `Diagnostics`; the app separates `UI` and `Conversation`. Provider-specific code lives under `backend/src/astra`. Demo hardware content remains outside those runtime modules. The [rack seed](assets/server-rack/README.md) contains 179 named nodes, references actual Dell service diagrams, and is bundled from its single canonical JSON file.

## Run locally

Install Node dependencies with `npm ci` in `backend`. The existing Doppler `backend/dev` config provides `OPENAI_API_KEY`; it stays in the backend process.

For the simulator or headless checks, run the loopback service:

```sh
cd backend
doppler run --project backend --config dev --only-secrets OPENAI_API_KEY -- npm start
```

It serves `http://127.0.0.1:8787/health` and `ws://127.0.0.1:8787/session`.

For a Mac-hosted physical-iPad session, run from the repository root in a separate terminal:

```sh
python3 tools/dev-session.py serve
```

This binds port 8788 to the Mac's Wi-Fi address and creates a temporary session token in the ignored `.local` directory with owner-only permissions. The iPad must reach that address. The authenticated HTTPS endpoint described in [backend-endpoint.md](docs/backend-endpoint.md) is a separately verified development route; it does not make the headless `SceneLab` harness a product backend or replace the local runtime configuration when that route is used.

Build the app in Xcode by opening `app/AstraSpatialDemo.xcodeproj`, selecting your development team and device, and running. XcodeGen's source is `app/project.yml`; regenerate from that directory with `xcodegen generate` after editing it. Device builds require Developer Mode and a trusted development profile. Simulator builds disable signing.

After installing a Debug app, launch it with the local backend settings prefilled, without printing the token:

```sh
python3 tools/dev-session.py launch --device 'iPad'
# Or, for an already installed simulator app (supply its UDID):
python3 tools/dev-session.py launch --simulator-id <SIMULATOR_UDID>
```

The app connects automatically using its configured or saved backend. Settings lets you change the connection; physical devices require a reachable host. Load the bundled rack, then tap a tabletop to place it. On a physical device, hand pointing runs automatically in the foreground and shows a fingertip cursor when a hand is visible. The composer's single action starts the microphone when empty and becomes Send when text is entered. Launching the app does not start microphone capture.

## Checks

```sh
swift test --package-path framework --scratch-path .local/build/framework
npm --prefix backend run typecheck
npm --prefix backend test
npm --prefix backend run build
swift run --package-path tools --scratch-path .local/build/tools PointingReplay --all
```

From the repository root, exercise the actual model with the same Swift reducer used by the app:

```sh
swift run --package-path tools --scratch-path .local/build/tools SceneLab validate assets/server-rack/scene.json
mkdir -p .local/evidence
swift run --package-path tools --scratch-path .local/build/tools SceneLab live \
  ws://127.0.0.1:8787/session \
  'Create a small editable fan with a hub and three blades.' \
  .local/evidence/my-fan.json
node tools/checks/realtime-smoke.mjs
```

These live checks call OpenAI. Deterministic tests inject a test transport and do not call the API. The [pointing replay](tools/pointing-replay.md) uses the product resolver and labels every input synthetic. A simulator or replay cannot establish real AR or camera-based pointing.

## Current boundary

The native app builds for simulator and device and has been signed, installed, and launched on the physical iPad with its rear-camera view visible over USB. Arav confirmed that its fingertip ring tracks and turns green over a part after the detector fix. Live Astra creation, rack edits, read-only explanations, a native simulator edit/Undo interaction, and Realtime synthetic text-to-audio have passed separate checks. Phone usability is prioritized for audience participation using the same universal implementation. Measured pointing accuracy, microphone/playback quality, and the combined spoken interaction still need their device trial.

The current authoring path accepts one complete bounded proposal per turn, with one repair attempt before delivery. It does not progressively install token fragments. Observed request times were about 10–24 seconds for the first small examples; this is a measured starting point, not a conversational-latency claim. The default Load rack path now uses the approved bundled Akeil USDZ catalog (`assets/imported-rack/app-catalog.json`), while the procedural six-shape path and generic approved detail expansion remain available for generated or revealed content. Manual SQLite checkpoint APIs exist; Save/Open UI and autosave are not connected yet. The [diagnostics contract](docs/diagnostics.md) explains JSONL/OSLog evidence and the boundaries of the Realtime tool smoke.

Arav has also completed a three-turn typed interaction on the physical iPhone: pull-out, explanation and arrows. [Event evidence](docs/evidence/iphone-heat-flow-session.json) verifies installations and final responses; his visual feedback motivates [richer spatial explanations and Images 2.5 research](docs/images-and-spatial-explanations.md).

Astra can request a generated 2D teaching illustration through the existing proposal tool. Images appear in a separate explanation panel while the editable scene remains available; follow-ups can refine the previous image. Generation, cancellation, retry, authenticated downloads and bounded caches are implemented. Real model/provider checks and both simulator layouts pass; exact visual fidelity and this stage’s physical-device rendering are still qualified in the [integration record](docs/images-2.5-integration-status.md).
