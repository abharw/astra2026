# Scripts

These are developer diagnostics and offline asset-build steps. They are not
runtime services. Generated source assets, Blender dependencies, renders, and
local receipts belong under ignored `runtime/` or `evidence/local/`.

| Script | Owner and purpose | Input/output boundary |
| --- | --- | --- |
| `dev-session.py` | Local session-service convenience commands | `serve` starts the local service. `doctor [--url HTTPS_ORIGIN]` checks a local or public health-compatible endpoint without an API call. `launch --url HTTPS_ORIGIN` preflights that endpoint, then launches with the saved development-service credential. |
| `check-model-access.py` | Direct OpenAI access probe | Requires an injected API key and writes only `evidence/local/model-access.json`. |
| `realtime-smoke.mjs` | Realtime audio-protocol smoke | Uses a running local service and prints a synthetic text/audio receipt; it does not write tracked evidence. |
| `check-realtime-tools.mjs` | Realtime forced-tool contract check | Uses a running local service and refreshes `evidence/realtime-tools-smoke.json`. |
| `prepare-mobile-rack.py` | Offline exterior-derivative experiment | Reads the pinned source in ignored `runtime/asset-source/`; writes ignored processed USDZ files and the selected measurement receipt. |
| `validate-mobile-rack.py` | Offline derivative structural validator | Runs inside Blender against the source and a derivative; it does not alter either asset. |
| `export-asset-groups.py` | Offline interior teaching-pack compiler | Reads the pinned Blender library in ignored `runtime/detail-source/`; writes an ignored pack/index and its declared receipt. |
| `prepare-selection-proxies.py` | Offline selection-box derivation | Reads the same pinned interior source plus compiler output; updates selection metadata and its declared receipt. |
| `check-asset-group-compiler.py` | Synthetic compiler-invariant acceptance check | Creates a desk-lamp fixture only beneath ignored `runtime/export-fixture/` and refreshes `evidence/asset-group-fixture.json`. |
| `check-imported-rack-native.py` | Native macOS import/install acceptance | Requires locally prepared ignored source/derivatives and refreshes `evidence/imported-rack-native.json`. |
| `asset_usd.py` | Shared USD storage helper | Imported by the interior compiler; it has no command-line ownership of its own. |

The two Realtime checks intentionally cover different contracts: `realtime-smoke.mjs` verifies the audio configuration and output path, while `check-realtime-tools.mjs` verifies forced `ask_astra` sequencing with a deliberately synthetic scene result. Neither establishes microphone, speaker, AR, or physical-device behavior.
