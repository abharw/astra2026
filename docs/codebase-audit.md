# Codebase map

This map covers the AR runtime and supporting code. The complete Akeil source tree is preserved separately in `app/VR/`; see [the integration record](ar-vr-integration.md). It distinguishes the runnable product from its contract tests, reproducibility tools, and hackathon evidence; it is not a claim that every directory is a public SDK.

| Path | Current role |
| --- | --- |
| `app/AR` | Shipping universal iPhone/iPad app. `project.yml` is the XcodeGen source; the tracked Xcode project is the generated project opened by Xcode. |
| `app/VR` | Independent Quest app, bridge, source assets, prototypes and historical records preserved from Akeil. |
| `backend` | AR local or authenticated-development session service: Realtime credentials, Astra proposal authoring, normalization, and acknowledged scene mirror. |
| `framework` | Shared Swift implementation. `SpatialCore` is the portable contract/reducer; `SpatialApple` is the RealityKit, input, transport, diagnostics, and storage adapter. |
| `assets` | App-bundled demo content and its provenance. `server-rack` is the authored procedural fallback; `imported-rack` is the default imported asset, its catalogs, assets, and notices. |
| `framework/contract` | Normative wire schema and portable fixtures shared by Swift and TypeScript checks. |
| `tools/Sources/SceneLab` | Headless live contract acceptance using the production reducer; it does not render or establish AR behavior. |
| `tools/Sources/PointingReplay` | Deterministic synthetic input replay using the production pointing resolver; it does not use a camera or establish device pointing. |
| `tools/assets`, `tools/checks`, `tools/dev-session.py` | Offline asset preparation, focused acceptance checks, and development entry points. |
| `docs/evidence` | Committed, dated acceptance records and captures. Historical payload path strings remain unchanged so their receipts retain their original provenance. |
| `.local`, `.local/build`, `.build`, `node_modules` | Ignored local state, build products, processed asset workspaces, and dependencies. They are deliberately absent from the repository. |

## Cleanup decisions

The earlier `examples/` directory became `content/`; the repository consolidation now places this data in `assets/`. Current source, test, tool, and documentation paths use `assets/`. Historical evidence JSON payloads retain their recorded paths and hashes.

The repository consolidation is implemented, verified, committed and pushed as `ef10dcb`. Backend, framework, headless tools, app builds, bundle resources, and an ordinary saved-endpoint iPhone launch passed. [The structure record](repository-structure-plan.md) preserves ownership rules and migration acceptance criteria.

`assets/imported-rack/source-catalog.json` remains repository provenance, but it is no longer copied into the iOS app bundle: no shipped code reads it. The app reads `app-catalog`, `detail-catalog`, and `detail-templates`; license notices remain bundled because the source review requires their retention.

Removed proven unused code: the app's manual hand-toggle method, unused activity text and loaded-asset label, redundant native-view initializer defaults, the backend's unused sink-replacement method and unused active-run fields. Automatic hand tracking, asset status, session ownership and the accepted-scene path retain their actual callers.

Public `SpatialKit` APIs and the two test tools are retained even where this repository has a small number of callers. They are explicit framework seams and acceptance infrastructure, rather than proven dead code.

`SpatialApple/Storage/SceneDocumentStore.swift` is compiled and tested but is not wired into the app: it provides manual SQLite checkpoint APIs only. Save/Open UI, autosave, restoration of imported assets after cache eviction, and AR anchor restoration are deferred. Treat it as a prepared SDK capability, not a current product promise; [storage.md](storage.md) describes that boundary.

For runtime deployment posture, [backend-endpoint.md](backend-endpoint.md) records the verified authenticated endpoint separately from the Mac-hosted local service and the headless testing tools.
