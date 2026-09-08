# Imported rack asset review

Reviewed the exterior asset at upstream `Akeil` commit `051c9d954292438fc8419661aa91451367961d86`. The source checkout is isolated under ignored `runtime/asset-source`; the primary checkout's branch and existing edits were preserved. No merge, push, or upstream source change was performed.

The pinned source is [abharw/astra2026/datacenter-rack](https://github.com/abharw/astra2026/tree/051c9d954292438fc8419661aa91451367961d86/datacenter-rack). The original binary is `runtime/asset-source/datacenter-rack/models/lazy/rack-exterior.usdz`: 25,786,225 bytes, SHA-256 `aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba`. Its size and hash match the committed Git LFS pointer. Because git-lfs is unavailable locally, only this binary was fetched through GitHub's pinned media endpoint. The 137 MB detail library, authoring masters, GLB alternative and 25 MB part-knowledge database were not downloaded.

## What the original USDZ contains

OpenUSD 26.03 and a real Blender 5.2.1 LTS import independently verified 18 instances and 55 visible mesh occurrences. The archive contains one `rack-exterior.usdc` and no textures. Its stage is Z-up with `metersPerUnit = 1` and default prim `root`.

| Measurement | Original exterior |
|---|---:|
| Authored mesh prims, including shared prototype | 38 |
| Unique authored vertices | 437,334 |
| Unique authored triangle equivalents | 791,123 |
| Server prototype triangles | 129,331 |
| Rack geometry triangles | 661,792 |
| Expanded visible triangles across 18 servers | 2,989,750 |
| Original material definitions | 17 |
| Authored material subsets | 48 |

Triangle equivalents count each polygon with `n` vertices as `n−2` triangles. Expanded triangle counts describe visible topology, not measured draw calls, frame time, resident memory or phone performance. The source's “80 objects / 21 mesh datablocks” describes the Blender default scene; its exporter converts curve primitives and expands collection structure. It is not the interchange mesh count.

## Identity and on-demand operations

All 18 server roots retain unique `part_id`, `server_id`, `asset_id`, slot and placement attributes. Server 3's path is `/root/rack01_·_Open_Rack_V2/rack01_server03`; its descendants are `rack01_server03_exterior/server_exterior_surface_0`. The latter references the shared prototype `/root/prototypes/server_exterior_surface_0`. Server root names run from `rack01_server01` through `rack01_server18`. The intake evidence includes their complete trusted path/ID/placement mapping.

This hierarchy supports independent server selection, translation, visibility and duplication in a native importer. It does not contain motherboard or CPU internals: `source/package_assets.py:98–117` merges and decimates exterior CAD surfaces into one shared server mesh. Mesh edits need explicit copying when only one instance should change. Custom metadata is present in the USD; native entity-name and metadata preservation must still be checked in the app's importer.

Cables remain children of the rack, not their associated server (`source/package_assets.py:141–152`). A server-only move therefore leaves its cables behind. Frame geometry is grouped by role. PSU IDs are intentionally reused across the separate hardware and power aggregates: each of `rack01.psu.01` through `.06` appears on two nodes. They are not globally unique entity keys.

The four detailed assets remain collections in `parts-library.blend`. The existing Blender loader caches by asset ID and instantiates detail under selected servers. Its implementation hides the exterior for all nonprocessor inspections even when the manifest's `replaces_exterior` flag is false. Processor study opens a separate explanatory scene. Another engine needs dedicated detail exports and its own load/cache/disposal operations; the original USDZ supplies none of these. See `docs/AGENT_USAGE.md:90–96`, `source/lazy_inspector.py:244–263`, and `docs/VERIFICATION.md:28–34` in the pinned source.

## Reproduced source geometry defect

The original rack structure measures 0.600 × 1.067 × 2.210 metres. Original whole-scene bounds are `[-0.3415, -0.8120773, 0]` to `[0.3000, 0.5335, 3.8616]` metres because two PSU 6 mesh groups are displaced above the rack. The affected mesh names are `rack01_psu_06_mesh` and `rack01_psu_06_mesh_001`, beneath `rack01_psu_06` and `rack01_psu_007`.

This was reproduced from the committed authoring code, not inferred from appearance alone. The origin-relocation loop in `source/rack_frame.py:204–210` restores children's world matrices without updating the dependency graph before processing the next nested assembly. Running the source in an empty Blender scene reproduces the USDZ's displaced PSU 6 bounds. Running it again with one added `bpy.context.view_layer.update()` after each restoration moves all 30 PSU 6 objects by `[0, +0.4, −1.908]` metres, with maximum numerical error below `1.3e-7` metres. All 150 objects belonging to PSU 1–5 remain unchanged. Corrected PSU 6 bounds become approximately `[-0.212, -0.4120773, 1.911]` to `[-0.143, 0.1314, 1.9536]` metres.

The intake retained the original binary unchanged. A mobile derivative should record any correction explicitly and recompute bounds before tabletop normalization. Scaling against the contaminated 3.8616-metre bounds would make the actual rack unexpectedly small. With source-to-Y-up mapping `[X, Z, −Y]`, the PSU correction is `[0, −1.908, −0.4]`. Confirm whether the native USD importer already converts the stage up-axis before applying any additional root rotation.

## Source notices and acceptance limits

Upstream `licenses/README.md` identifies Zaius/Barreleye G2 derivatives as OCPHL-P with the IBM notice, and the authored Open Rack V2 frame reconstruction as OCPHL-R. Its IBM notice requests preservation of the entire notice page in derivatives. Include the supplied license files, attribution and the pinned editable-source reference alongside the imported or optimized model. The source notices do not relicense unrelated application code or third-party silicon.

The upstream `check_package.py` was read before execution. It exits at the first intentionally unfetched Blender binary, so the full package check is **not passed**. The downloaded USDZ separately passed archive integrity, LFS hash verification, OpenUSD parsing, server-identity inspection and actual Blender import. Original source receipts establish Blender bridge behavior and GLB structure; they explicitly do not establish RealityKit behavior or headset performance.

Measured evidence is in [`evidence/asset-intake.json`](../evidence/asset-intake.json). The retained [`PSU defect reproducer`](../evidence/rack-psu-offset-reproduction.py) runs with Blender against that pinned source checkout and writes only beneath ignored `runtime/asset-source`. Intermediate inspection reports and the `inspect_pxr_usdz.py` / `inspect_blender_usdz.py` scripts remain there. Native loading, device appearance, frame time, interaction and combined imported/procedural edits require separate application acceptance evidence.
