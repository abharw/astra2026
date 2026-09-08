# Data-center maze video experiment

A regular 30-second POV route: straight, left, right, left, then a look back. The purpose is to test video-to-floor-map inference against a fixed authored source.

First version, rejected by the user for robotic motion and artificial labels: [1080p maze walkthrough](datacenter-maze-walkthrough.mp4), 29.708 seconds. Sampled visual review confirms the requested turn sequence and fixed junction landmarks. [Generation receipt and limits](generation-result.json).

- `datacenter-world.blend`: complete editable source with source-based rack exteriors.
- `floor-plan.json`: metric gallery union, wall/rack bounds, landmarks and all 720 camera poses.
- `floor-plan.png`: ground-truth diagram, kept separate from video-only test input.
- `geometry-check.json`: camera clearance and layout checks.
- `generation-prompt.txt`: reference-led video prompt.
- `JOURNEY.md`: attempts, tutorial study, corrections and verification status.
- `attempts/`: previous prompts and sanitized generation receipts.

Use the final video alone as the mapper input. Withhold this folder's map, poses, prompts and landmark descriptions until scoring. A video generated from the Blender reference may introduce geometry drift; metric agreement is not established by conditioning alone. Ground truth is exact only for the deterministic Blender source and its direct renders.

The [smooth revision](smooth/README.md) addresses that feedback with rounded continuous walking turns and no labels.

## Reproduction

Use Blender 5.3 Alpha (baf26f9a6b9b), or adapt the EEVEE engine enum to a compatible release. From the repository root, with `BLENDER_BIN` set to the actual app executable:

```sh
"$BLENDER_BIN" -b -P datacenter-rack/walkthrough/build_world.py
python3 datacenter-rack/walkthrough/check_geometry.py
python3 datacenter-rack/walkthrough/draw_plan.py
"$BLENDER_BIN" -b datacenter-rack/walkthrough/datacenter-world.blend -P datacenter-rack/walkthrough/render_reference.py
```

`draw_plan.py` uses Pillow and a macOS Arial font path. The motion reference uses graybox proxies at the evaluated rack bounds; the high-detail source and a rack appearance reference remain separate. Run `python3 datacenter-rack/walkthrough/encode_reference.py` after rendering the frames. See the journey for actual model parameters. Original straight-room source/reference files are superseded historical artifacts.

## Interpreting a mapping result

Score the recovered left/right/left route, corridor adjacency, separation of parallel galleries, fixed landmarks and consistency on the final look-back. Do not treat unobserved vestibule boundaries as recovered evidence. Absolute metric scale is ambiguous from an uncalibrated monocular clip; the authored metric plan is an answer key, not proof that those dimensions can be uniquely recovered from video alone.

`render_lit.py` is an optional direct-render lighting variant with unchanged geometry and camera. It aligns area lights with the visible fixtures instead of putting them behind the cable tray. Its still previews are a source rendering study, not the generated video.
