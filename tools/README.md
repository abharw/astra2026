# Acceptance tools

`tools/` contains small clients that exercise production library code without
becoming alternate applications or renderers.

| Tool | Command | What it establishes |
| --- | --- | --- |
| `SceneLab` | `swift run --package-path tools/SceneLab SceneLab validate SCENE` | A scene document is accepted by the production `SceneState` reducer. `seed OUTPUT` regenerates the authored seed; `live WS_URL PROMPT EVIDENCE [STARTING_SCENE]` records a real service-to-Swift-reducer acceptance run. It does not render or claim AR behavior. |
| `PointingReplay` | See [PointingReplay/README.md](PointingReplay/README.md) | Named synthetic landmarks pass through the production mapper and pointing resolver. It is a deterministic diagnostic, not a camera, Vision, or renderer substitute. |

The app owns rendering, camera input, and device behavior. The testing lanes and
their evidence limits are defined in [docs/testing-harness.md](../docs/testing-harness.md).
