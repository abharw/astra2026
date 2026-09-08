# Data-center maze video experiment

A regular 30-second POV route: straight, left, right, left, then a look back. The purpose is to test video-to-floor-map inference against a fixed authored source.

Current production status: editable maze and geometric checks complete; motion reference rendering; photoreal video generation and visual acceptance pending.

- `datacenter-world.blend`: complete editable source with source-based rack exteriors.
- `floor-plan.json`: metric gallery union, wall/rack bounds, landmarks and all 720 camera poses.
- `floor-plan.png`: ground-truth diagram, kept separate from video-only test input.
- `geometry-check.json`: camera clearance and layout checks.
- `generation-prompt.txt`: reference-led video prompt.
- `JOURNEY.md`: attempts, tutorial study, corrections and verification status.
- `attempts/`: previous prompts and sanitized generation receipts.

Use the final video alone as the mapper input. Withhold this folder's map, poses, prompts and landmark descriptions until scoring. A video generated from the Blender reference may introduce geometry drift; metric agreement is not established by conditioning alone. Ground truth is exact only for the deterministic Blender source and its direct renders.

## Reproduction

Use Blender 5.3 Alpha (baf26f9a6b9b), or adapt the EEVEE engine enum to a compatible release. From the repository root, with `BLENDER_BIN` set to the actual app executable:

```sh
"$BLENDER_BIN" -b -P datacenter-rack/walkthrough/build_world.py
python3 datacenter-rack/walkthrough/check_geometry.py
python3 datacenter-rack/walkthrough/draw_plan.py
"$BLENDER_BIN" -b datacenter-rack/walkthrough/datacenter-world.blend -P datacenter-rack/walkthrough/render_reference.py
```

`draw_plan.py` uses Pillow and a macOS Arial font path. The motion reference uses graybox proxies at the evaluated rack bounds; the high-detail source and a rack appearance reference remain separate. See the journey for actual encoding and model parameters. Original straight-room source/reference files are superseded historical artifacts.
