# Smooth, unlabelled data-center walkthrough

Revision prompted by the user finding the first maze camera robotic and asking for smoother motion/panning and no BAY labels.

The same room now uses a continuous 21.94 m rounded walking path with left, right, left turns. Camera translation continues through the bends, with gentle heading anticipation. At 23.5 seconds it begins a slower 6.5-second, 160-degree look-around. All font objects and artificial colored wayfinding have been removed; ordinary neutral utility panels remain.

`blender-motion-reference.mp4` is the exact authored camera/geometry source. `datacenter-world.blend` contains the full rack geometry. `floor-plan.json` stores all 720 poses and the unchanged room bounds. `floor-plan.png` is a separate answer key. `geometry-check.json` and `motion-check.json` record geometric clearance and motion properties. The maximum authored pan speed is 38.7 degrees/s, versus roughly 112.5 degrees/s for the first maze's final pan.

The photoreal generation uses the motion video plus the original rack appearance image. Its prompt, source hashes and model schema are recorded alongside the output. The source map is exact for Blender; AI-generated metric fidelity requires separate evaluation. Do not supply this answer key to the mapping system with its test video.

## Reproduce

Run `build_motion.py` in Blender; it opens the parent folder's saved world. Open this folder's resulting blend and run `render_reference.py`, then use Python to run `encode_reference.py`. `draw_plan.py` needs Pillow. Run `check_geometry.py` after any path or geometry edits.
