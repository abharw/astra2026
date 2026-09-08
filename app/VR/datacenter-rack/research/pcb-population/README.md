# Zaius EVT3 source PCB population

`../../source/pcb_population.py` builds the populated motherboard from the retained EVT3 ODB++ and PWA BOM. It creates 6,663 independently selectable component objects using 177 shared mesh variants. This is a source-data reconstruction of external package bodies and terminals, not exact manufacturer mechanical models or chip internals.

## Integration contract

Inside Blender, call `build_pcb_population(parent=None, skip_refdes=None)`. The result is a dictionary with `root`, `objects`, and JSON-serializable `metadata`. `metadata.parts` is keyed by `pcb.<reference designator>`; `metadata.receipt` records counts, source hash, units and skips. A caller-supplied parent defines the assembly alignment.

Coordinates are meters: X is original ODB x, Y is original ODB y, and positive Z is the board normal. The top surface is Z=0 and the bottom surface is Z=-0.003m. The original EVT mechanical drawing states board thickness 3.00±0.30mm. `board_thickness_mm` may override it, and the receipt records the override. The generator creates neither a substrate nor a world placement.

Use the real CAD socket/mounting locations to align the board. U1 center is (84.360004, 341.199978) mm and U10 center is (247.879870, 341.199978) mm. The caller owns matching CAD components and supplies actual duplicate refdes through `skip_refdes`, accepting either `U1` or `pcb.U1` form. There is no hardcoded skip list.

Default creation includes only PWA-BOM-listed parts: 3,810 top and 2,853 bottom. The source has 7,867 distinct designators, including 1,006 DEPOP entries and 198 unresolved entries. Unresolved entries are excluded. Optional `include_depop_pads=True` creates pads for DEPOP entries with no physical package body and explicit population metadata.

Each object includes its source reference, manufacturer, manufacturer part number, component class, BOM evidence, and evidence level. Function text describes the documented component type; electrical roles are not guessed from placement. Planar body outlines and individual terminal/pad contours come from the EDA package records. Z extrusion, chamfer, terminal thickness and material appearance are inferred. J110 has zero source instance height; its 10.100056mm height is inherited from the same package/manufacturer-part peers and recorded explicitly. Published manufacturer STEP geometry should replace these package reconstructions where available.

## Fabrication maps

Six grayscale `textures/*.png` files were rendered from the same EVT3 Gerber release. They are 4,797×8,192 pixels over the exact ODB profile bounding rectangle, (0,0)–(330.2,563.88)mm. Full profile and drill cutouts remain the substrate mesh's responsibility. Raster pitch is approximately 0.0688mm; narrower features are antialiased.

| Maps | White-pixel meaning |
| --- | --- |
| `top-copper.png`, `bottom-copper.png` | Copper feature |
| `top-mask-openings.png`, `bottom-mask-openings.png` | Opening in solder mask |
| `top-silkscreen.png`, `bottom-silkscreen.png` | Original silkscreen feature |

UV mapping on both sides is `u=x_mm/330.2`, `v=y_mm/563.88`. PNG row zero is maximum ODB y. Do not mirror bottom U; its lettering appears reversed from above because it becomes readable from below. Set image color space to Non-Color when using maps as masks. Texture polarity specifies feature occupancy, not final appearance. Material color, coating thickness, copper relief and exposed plating require caller tuning. Any fabrication legends beyond board bounds are cropped.

Original Gerbers use obsolete aperture primitive 22. Gerbonara 1.6.3 rejected this primitive. `prepare_textures.py` converts retained derivative copies to equivalent primitive 21 using center=(lower-left+half-size), while preserving exposure, dimensions and origin-centered rotation. The semantics follow Ucamco Gerber specification section 8.2.5. Numeric inputs are required; no unsupported expression is silently dropped. Original files remain under `source-layers/`; normalized copies are separate. Tool versions are frozen in `requirements-frozen.txt`.

## Evidence and checks

- `source-prepare-receipt.json`: all 7,867 local EDA pin transforms matched against named absolute ODB pin records. Maximum error is 0.00010668mm. Matching by pin name corrects differing source array orders.
- `smoke-receipt.json`: Blender 5.3.0 Alpha build baf26f9a6b9b constructed all 6,663 parts in 1.77 seconds. Top/bottom surface checks and explicit duplicate-skip checks passed. Maximum object-center float error is 2.98×10⁻⁸m. Shared mesh geometry totals 194,084 vertices and 113,804 faces in the isolated smoke file.
- `pcb-population-smoke.blend`: compressed isolated assembly; no camera render or integrated rack acceptance is implied.
- `smoke-metadata.json`: per-designator records from the full smoke build.
- `textures/texture-receipt.json`: source/output SHA-256 hashes, dimensions, original feature bounds, conversion counts and timings.
- `textures/registration-check.json`: independent Gerber-mask sampling of populated ODB pin centers. Within 2px (0.138mm), 30,676 of 30,709 top pins and all 6,201 bottom pins meet mask openings. Both POWER9 sockets match all 3,909 pins each. This confirms registration; the 33 remaining top pins are not asserted to be fabrication errors.
- `*-preview.png`: inspection derivatives. Top copper, top mask, top silk and bottom silk were visually inspected. This does not claim a manual audit of every trace or label.

The root assembly owner remains responsible for actual STEP alignment, duplicate matching, shader tuning, final render and live inspection. No heavy Blender render was run for this bounded module.

## Rebuild

Run `prepare_source.py` with system Python from the workspace root. It reads retained ODB++/placement/BOM derivatives using recorded paths. Run the Blender `smoke_test.py` with the pinned application executable. Run `.venv/bin/python prepare_textures.py` to regenerate all six fabrication maps; `--height` changes raster resolution and `--layers` selects maps. A partial layer invocation replaces the texture receipt with that invocation's layer list.

Source repository: https://github.com/opencomputeproject/zaius-barreleye-g2 at commit `125c5c264c26f97550da8c19539becb71cf7dc6c`. Release: EVT3 X02 2016-12-26; BOM X15 2017-01-06. Hardware design files carry OCPHL-P-1.0 under the retained repository notice. Tooling is separately licensed. Source acquisition and rights evidence are retained in `../../../research/ocp-candidates/`; execution actions are in `../../logs/pcb-population-actions.jsonl`.
