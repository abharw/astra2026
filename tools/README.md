# Development and acceptance tools

`tools/` contains offline asset preparation, development commands, and small clients that exercise production modules. It is not imported by the running app or backend. Run the commands below from the repository root.

| Tool | Command | What it establishes |
| --- | --- | --- |
| `SceneLab` | `swift run --package-path tools --scratch-path .local/build/tools SceneLab validate SCENE` | A scene document is accepted by the production `SceneState` reducer. `seed OUTPUT` regenerates the authored seed; `live WS_URL PROMPT EVIDENCE [STARTING_SCENE]` records a real service-to-Swift-reducer acceptance run. It does not render or claim AR behavior. |
| `PointingReplay` | `swift run --package-path tools --scratch-path .local/build/tools PointingReplay --all` | Named synthetic landmarks pass through the production mapper and pointing resolver. See [replay usage](pointing-replay.md) for individual cases and receipt output. It is a deterministic diagnostic, not a camera, Vision, or renderer substitute. |

Both executables are targets of [Package.swift](Package.swift), using `SpatialCore` and `SpatialApple` from `framework`. PointingReplay keeps its MainActor isolation. Create an output directory before asking either executable to save a receipt; new local receipts belong under `.local/evidence/`.

## Development and offline scripts

Generated source assets, Blender dependencies, renders, and build output belong under ignored `.local/`. Existing committed receipts live in `docs/evidence/`; their historical payload paths and hashes are preserved.

| Script | Purpose | Input/output boundary |
| --- | --- | --- |
| [dev-session.py](dev-session.py) | Local session-service convenience commands | `serve` starts the local service. `doctor [--url HTTPS_ORIGIN]` checks health without an API call. `launch --url HTTPS_ORIGIN` preflights that endpoint and launches with the saved credential. Private settings remain in `.local/dev-session.json`. |
| [checks/check-model-access.py](checks/check-model-access.py) | Direct OpenAI access probe | Requires an injected API key and writes `.local/evidence/model-access.json`. |
| [checks/realtime-smoke.mjs](checks/realtime-smoke.mjs) | Realtime audio-protocol smoke | Uses a running local service and prints a synthetic text/audio receipt; it does not write tracked evidence. |
| [checks/check-realtime-tools.mjs](checks/check-realtime-tools.mjs) | Realtime forced-tool contract check | Uses a running local service and refreshes `docs/evidence/realtime-tools-smoke.json`. |
| [assets/prepare-mobile-rack.py](assets/prepare-mobile-rack.py) | Offline exterior-derivative experiment | Reads the pinned source in `.local/asset-source/`; writes ignored processed USDZ files and the selected measurement receipt. |
| [assets/validate-mobile-rack.py](assets/validate-mobile-rack.py) | Offline derivative structural validator | Runs inside Blender against the source and a derivative; it does not alter either asset. |
| [assets/export-asset-groups.py](assets/export-asset-groups.py) | Offline interior teaching-pack compiler | Reads the pinned Blender library in `.local/detail-source/`; writes an ignored pack/index and its declared receipt. |
| [assets/prepare-selection-proxies.py](assets/prepare-selection-proxies.py) | Offline selection-box derivation | Reads the same pinned interior source plus compiler output; updates selection metadata and its declared receipt. |
| [checks/check-asset-group-compiler.py](checks/check-asset-group-compiler.py) | Synthetic compiler-invariant acceptance | Creates a desk-lamp fixture beneath `.local/export-fixture/` and refreshes `docs/evidence/asset-group-fixture.json`. |
| [checks/check-imported-rack-native.py](checks/check-imported-rack-native.py) | Native macOS import/install acceptance | Requires locally prepared source/derivatives and refreshes `docs/evidence/imported-rack-native.json`. |
| [assets/asset_usd.py](assets/asset_usd.py) | Shared USD storage helper | Imported by the interior compiler; it has no command-line ownership of its own. |

The two Realtime checks cover different contracts: `realtime-smoke.mjs` verifies audio configuration and output, while `check-realtime-tools.mjs` verifies forced `ask_astra` sequencing with a deliberately synthetic scene result. Neither establishes microphone, speaker, AR, or physical-device behavior.

The app owns rendering, camera input, and device behavior. The testing lanes and
their evidence limits are defined in [docs/testing-harness.md](../docs/testing-harness.md).

## Native flow acceptance

[Flow integration and evidence](../docs/native-flow-integration.md) separates real-model scene acceptance from native rendering and physical-device performance.

```sh
swift build --package-path tools --scratch-path .local/build/flow-check --product SceneLab
node tools/checks/check-flows.mjs --prepare-only
node tools/checks/check-flows.mjs --out .local/flow-acceptance/live
```

[check-flows.mjs](checks/check-flows.mjs) runs rack and non-rack creation, reversal, bound-part translation, hide, delete, and host Undo through the production Swift reducer. It uses real model authoring for the first five stages, supplies synthetic phone snapshots with no invented measured bounds, and saves receipts/documents only under `.local/`. `--prepare-only` validates the fixtures without network access.

[check-flow-metrics.py](checks/check-flow-metrics.py) restarts an installed Debug app for each selected 0/1/8/32-flow fixture and records 30 active seconds per count:

```sh
python3 tools/checks/check-flow-metrics.py --simulator-id <SIMULATOR_UDID> \
  --counts 0,1,8,32 --out .local/flow-metrics/simulator
python3 tools/checks/check-flow-metrics.py --device <DEVICE_ID> \
  --counts 0,1,8,32 --out .local/flow-metrics/device
```

Use a new output directory. The explicit Debug launch setting `ASTRA_FLOW_ACCEPTANCE_COUNT` selects a synthetic fixture; ordinary launches do not. Reports measure marker-loop CPU wall time, bounded resources, and scene-update callback cadence. Simulator results never establish physical AR, GPU time, thermal behavior, or visual correctness; physical runs require an unlocked device.

### Realtime audio checks

`python3 tools/checks/check-audio-callback-isolation.py --before-ref 8d93cb3` compiles the actual conversation sources to SIL with app isolation settings and checks the audio callback boundary. `node tools/checks/check-realtime-audio-clock.mjs` replays generated PCM against one real Realtime session before and after clearing the input buffer. It silently uses the local development session configuration, makes provider calls, and writes redacted receipts under `.local/realtime-audio-clock`; it does not record or play the native microphone.
