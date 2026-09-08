# Pointing replay tool

Small deterministic diagnostic for the production `SpatialApple` viewport mapper and pointing resolver. It has no camera, renderer, or permission UI. Real gesture acceptance happens on the physical iPad with screen mirroring or capture.

Run from the repository root:

```sh
mkdir -p .local/evidence
swift run --package-path tools --scratch-path .local/build/tools PointingReplay --all --output .local/evidence/pointing-replay.json
```

Use `--case CASE_ID` to run one case or `--help` to list the available cases. The Swift package preserves the tool's MainActor isolation.

See [testing-harness.md](../docs/testing-harness.md) for the evidence boundary and simulator lane.
