# AR and VR integration

September 8, 2026. The apps coexist with their existing pipelines. This is a repository integration; no runtime, scene-protocol, or backend unification is included.

## Source and branch boundary

Integration branch: `codex/ar-vr-integration`.

| Source | Preserved revision | Destination |
| --- | --- | --- |
| Arav | `d70f39fbc5cc4f3779b077631f999a8e5355e6d8` | Existing root tree, with its app moved into `app/AR/` |
| Akeil | `98dfc61ffcdd5753bfe793e7580ad37018ddd654` | Entire tree preserved under `app/VR/` |

Both tips were refreshed before integration. Arav's previously uncommitted native flows and microphone/Realtime changes had been committed in `58f98a0` and `d70f39f`; both are included. Akeil's latest local rack demo, voice indicator, and placement-size controls are also included. Its subsequent documentation-only deployment update (`98dfc61`) was incorporated before finalizing; the verified application, backend and asset bytes are unchanged by that update.

The source histories have no common ancestor. The integration records both commits as merge parents and preserves Akeil's complete tree as a subtree. Neither original branch was rewritten, and `main` was not changed. The work is isolated in `/Users/aravb/Developer/astra2026-ar-vr`; the original `/Users/aravb/Developer/astra2026` checkout remains on Arav.

## Layout

```text
app/
  README.md                       # Choose an app and its setup instructions
  AR/
    AstraSpatialDemo.xcodeproj
    project.yml
    SpatialDemo/
    Tests/
    README.md
  VR/                             # Exact complete Akeil source tree
    quest/                        # Unity/OpenXR Quest application
    spatial-assembly/
      server/                     # Quest bridge
      ios/                        # Earlier Akeil iOS implementation
      configure.py
    datacenter-rack/
    browser-prototype/
    research/
    docs/
    README.md
backend/                          # AR session service
framework/                        # AR SpatialCore/SpatialApple + v1 contract
assets/                           # AR approved assets/catalogs
tools/                            # AR development, asset and acceptance tools
docs/                             # AR documentation and this integration record
```

All 3,553 Akeil files retain their source bytes and Git modes. Its nested `.gitignore` and `.gitattributes` preserve the original scope: Quest caches and private pairing files stay ignored; its LFS declarations still apply to the source asset library. Unity `.meta` files, packages, project settings, runtime exports, source assets, prototypes and historical records are retained together.

The imported documentation's repository-root commands assume `app/VR/` as the working directory. Keeping the entire tree makes its sibling-relative pairing and export paths continue to resolve. Its earlier iOS app and browser prototype remain available but do not replace the AR app.

## Run AR

From the combined repository root:

```sh
npm --prefix backend ci
python3 tools/dev-session.py serve
```

Use the existing AR backend credential setup described in [the root README](../README.md). Open `app/AR/AstraSpatialDemo.xcodeproj` in Xcode. To regenerate or build the project:

```sh
cd app/AR
xcodegen generate
xcodebuild -project AstraSpatialDemo.xcodeproj \
  -scheme AstraSpatialDemo \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../.local/build/ios \
  CODE_SIGNING_ALLOWED=NO build
```

The XcodeGen package and asset paths now use `../../framework` and `../../assets`. Swift source, app identity and bundled content are preserved. The callback-isolation check uses the relocated current sources while retaining the original paths for historical `--before-ref` comparisons.

## Run VR

From the combined repository root:

```sh
cd app/VR
npm --prefix spatial-assembly/server ci
# Start an HTTPS tunnel to localhost:8796 separately.
python3 spatial-assembly/configure.py https://YOUR-TUNNEL-HOST
python3 spatial-assembly/server/launch.py
```

Open `app/VR/quest/` as the Unity project. The source pins Unity `6000.3.23f1`; see [Quest setup](../app/VR/quest/README.md) for Android support and package requirements. The pairing script keeps its existing token unless explicitly rotated and writes private configuration for the imported clients. This integration does not copy private pairing files from another checkout, generate new credentials, restart running services, or install applications.

Runtime rack exports are regular Git blobs. Historical `datacenter-rack` source assets use Git LFS; fetch those binaries when reproducing the earlier asset pipeline. The two apps retain separate service ports and connection settings: AR's device development launcher defaults to 8788 (plain backend default 8787), and the VR bridge defaults to 8796.

## Verification

- AR backend: TypeScript check, 206 deterministic tests, and production build pass in the integration worktree.
- AR relocation: all original app files remain present; Swift sources and `Info.plist` match the Arav source commit. Project package/resource paths and local app documentation links resolve.
- AR native build: isolated simulator build-for-testing passes for the app and Realtime test target, including arm64 and x86_64. All 33 Realtime tests pass across three suites on the iPhone 17 Pro Max simulator. Logs, the result bundle, and the relocation receipt are retained in `.local/integration-validation/`.
- VR import: all 3,553 files match the Akeil commit's Git blob IDs and modes, with no missing or added source files inside `app/VR/`.
- VR backend: 22 deterministic tests pass in the integration worktree.
- VR assets: all ten `.rackbin` packages match their catalog hashes and byte counts, decompress to the declared sizes, and have the expected header and mesh counts; total compressed bytes: 19,872,989.
- Nested ignore/attribute rules retain their intended scope and do not hide AR Xcode files or root evidence.

The backend checks use mocked model calls. No new Unity/Android build, physical-device interaction, live model request, or combined demonstration is claimed. Both pipelines continue to require their own device acceptance and runtime configuration.

## Scope

The shared rack content does not imply interoperable scene protocols. AR retains its Swift reducer and v1 receipt-based scene service. VR retains its Unity assembly model and protocol-2 bridge, native controls, camera reconstruction and local anchor persistence. Folder names do not introduce shared live scenes or cross-device anchors.

Future changes can be made independently on either source branch and deliberately integrated into the corresponding directory. Promotion to `main` is a separate step after review and both demos' acceptance.
