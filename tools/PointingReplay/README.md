# Astra pointing replay tool

Small deterministic diagnostic for the production `SpatialApple` viewport mapper and pointing resolver. It has no camera, renderer, or permission UI. Real gesture acceptance happens on the physical iPad with screen mirroring or capture.

```sh
cd tools/PointingReplay
xcodegen generate
xcodebuild -project AstraPointingReplay.xcodeproj -scheme AstraPointingReplay -destination 'platform=macOS' -derivedDataPath .derived-data build
.derived-data/Build/Products/Debug/astra-pointing-replay --all --output pointing-replay.json
```

See [`docs/testing-harness.md`](../../docs/testing-harness.md) for the evidence boundary and simulator lane.
