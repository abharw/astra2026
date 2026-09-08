# Reproduce and extend the asset

## Use the shipped assets first

The full detailed master and four-collection detail library are tracked with Git LFS. `git lfs pull` supplies them without a CAD conversion or a new generation call. Running `scripts/launch_rack.py` opens the exterior-only scene. No render is required for inspection or lazy loading.

## Repackage the delivered master

Run these from the repository root with `BLENDER_BIN` pointing at the tested Blender executable. Packaging replaces the generated `models/lazy` files; preserve any deliberate edits separately first.

```sh
"$BLENDER_BIN" -b datacenter-rack/models/datacenter-rack-v002.blend -P datacenter-rack/source/package_assets.py
"$BLENDER_BIN" -b datacenter-rack/models/lazy/rack-exterior.blend -P datacenter-rack/source/export_runtime.py
python3 datacenter-rack/scripts/check_package.py
```

The packager extracts four detail collections, combines and simplifies the exterior CAD, preserves server roots/IDs, and writes a fresh exterior-only scene. The exporter writes GLB/USDZ and adds their paths to the manifest. The scripts use paths relative to their own location. The initial packaging run took about five minutes; it is an offline authoring step.

## Rebuild the full master from retained mesh derivatives

The reusable source mesh package, assembly hierarchy, PCB population data, six fabrication texture maps and accepted repair derivatives are included. The giant original multi-variant Blender import is a regenerable local intermediate.

```sh
"$BLENDER_BIN" -b --factory-startup -P datacenter-rack/source/import_cad.py -- --mesh-dir datacenter-rack/models/barreleye-evt-mesh --output datacenter-rack/models/barreleye-source-v001.blend
"$BLENDER_BIN" -b --factory-startup -P datacenter-rack/source/build_asset.py
"$BLENDER_BIN" -b --factory-startup -P datacenter-rack/source/finish_asset.py
```

These stages import the full source hierarchy, select the coherent EVT3 configuration, generate the source-based PCB population and rack/cabling, then apply surface/material repairs and add the explanatory processor study. They save versioned models. Rendering is optional and is never part of a question-time load.

## Reacquire original hardware and regenerate source derivatives

Acquisition provenance and exact source URLs/hashes live in `../research/ocp-candidates/source-register.jsonl` and its `findings.md`. The public Zaius/Barreleye repository is pinned at `125c5c264c26f97550da8c19539becb71cf7dc6c`; use the EVT neutral STEP and EVT3 electrical files, preserving the source notices.

The acquisition entrypoints are `../research/ocp-candidates/scripts/acquire.py`, `acquire_evt.py`, and `inspect_evt_odb.py`. Read their configured destinations and the register before rerunning. They are production research scripts, not a portable one-command installer. Original downloads, archive extractions and the CAD Python environment are intentionally excluded from Git.

`scripts/step_to_mesh.py --help` documents the OpenCascade converter. Its dependencies are Python, cadquery-ocp/OCP and NumPy; the PCB texture pipeline additionally records frozen requirements in `research/pcb-population/requirements-frozen.txt`. Consult `research/pcb-population/README.md` to rebuild BOM/ODB population and Gerber textures, and `research/cad-diagnostics/README.md` for accepted surface repairs and independent bounds validation. Those research stages expect reacquired originals at their recorded paths. The packaged-asset and retained-mesh routes above avoid those downloads.

## Extend the saved library

Create a separate collection with stable part IDs and evidence metadata; write it to a `.blend` library; add its path, collection, units, bounds and dependencies to the manifest. Extend `lazy_inspector.ASSET_IDS`, the sidebar and resolver mapping deliberately, then validate append/cache/unload behavior. Adding a manifest row alone does not expand the current four-asset allowlist. Keep new engine exports separate from the authoritative editable source and preserve source/inference metadata in both.
