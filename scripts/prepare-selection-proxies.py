#!/usr/bin/env python3
"""Derive small interaction proxies from recipe-selected source assembly clusters.

The output catalog keeps its asset bytes, digest and resource URL. Only optional
selection metadata changes. No domain names or hierarchy levels are built in.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--blender", default="/Applications/Blender.app/Contents/MacOS/Blender"
    )
    parser.add_argument(
        "--input", type=Path, default=ROOT / "runtime/detail-source/parts-library.blend"
    )
    parser.add_argument(
        "--recipe",
        type=Path,
        default=ROOT / "content/imported-rack/teaching-groups.json",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT / "content/imported-rack/detail-levels.json",
    )
    parser.add_argument(
        "--index",
        type=Path,
        default=ROOT / "runtime/processed-assets/server-teaching-source-index.json",
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=ROOT / "runtime/processed-assets/server-teaching.catalog.json",
    )
    parser.add_argument(
        "--evidence", type=Path, default=ROOT / "evidence/server-selection-proxies.json"
    )
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    args = parser.parse_args(argv)
    try:
        import bpy
    except ImportError:
        return subprocess.run(
            [
                args.blender,
                "--background",
                "--factory-startup",
                "--python-exit-code",
                "1",
                "--python",
                str(Path(__file__).resolve()),
                "--",
                *sys.argv[1:],
            ],
            check=False,
        ).returncode
    from mathutils import Matrix, Quaternion, Vector

    recipe = json.loads(args.recipe.read_text())
    manifest = json.loads(args.manifest.read_text())
    index = json.loads(args.index.read_text())
    catalog = json.loads(args.catalog.read_text())
    source_sha = hashlib.sha256(args.input.read_bytes()).hexdigest()
    if source_sha != recipe["source"]["sha256"] or source_sha != index["sourceSHA256"]:
        raise ValueError("Source library, recipe and source index disagree.")
    expected_asset = catalog["assetID"]
    expected_digest = catalog["sha256"]
    definitions = {recipe["partIDPrefix"] + row["id"]: row for row in recipe["groups"]}
    parts = {row["partID"]: row for row in manifest["parts"]}
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    with bpy.data.libraries.load(str(args.input), link=True) as (available, requested):
        requested.collections = list(recipe["collections"])
    objects = set()
    for collection in requested.collections:
        bpy.context.scene.collection.children.link(collection)
        objects.update(collection.all_objects)
    bpy.context.view_layer.update()
    by_id = {}
    for obj in objects:
        part_id = obj.get("part_id")
        if part_id:
            by_id.setdefault(part_id, []).append(obj)

    evidence_parts = []
    total = 0
    for part in catalog["parts"]:
        definition = definitions[part["partID"]]
        selection = definition.get("selection")
        if selection is None:
            continue
        if selection["kind"] == "none":
            part["selection"] = {"kind": "none"}
            evidence_parts.append(
                {"partID": part["partID"], "kind": "none", "boxCount": 0}
            )
            continue
        if selection["kind"] != "sourceClusters":
            raise ValueError("Unsupported source selection recipe.")
        transform = parts[part["partID"]]["sourceRestTransform"]
        x, y, z, w = transform["rotation"]
        inverse = Matrix.LocRotScale(
            Vector(transform["translation"]),
            Quaternion((w, x, y, z)),
            Vector(transform["scale"]),
        ).inverted()
        represented = {row["blenderObject"] for row in index["parts"][part["partID"]]}
        boxes, clusters = [], []
        for root_id in selection["roots"]:
            matches = by_id.get(root_id, [])
            if len(matches) != 1:
                raise ValueError(
                    f"Expected one source cluster {root_id}, found {len(matches)}."
                )
            root = matches[0]
            descendants = [root, *root.children_recursive]
            visible = [
                obj
                for obj in descendants
                if obj.name in represented and obj.type in {"MESH", "CURVE", "FONT"}
            ]
            points = [
                inverse @ obj.matrix_world @ Vector(corner)
                for obj in visible
                for corner in obj.bound_box
            ]
            if not points:
                raise ValueError(
                    f"Cluster {root_id} has no represented source geometry."
                )
            low = [min(point[axis] for point in points) for axis in range(3)]
            high = [max(point[axis] for point in points) for axis in range(3)]
            size = [high[axis] - low[axis] for axis in range(3)]
            center = [(high[axis] + low[axis]) / 2 for axis in range(3)]
            if not all(math.isfinite(value) for value in center + size) or not all(
                value > 0 for value in size
            ):
                raise ValueError(f"Invalid interaction box for {root_id}.")
            boxes.append({"center": center, "size": size})
            clusters.append(
                {
                    "sourceRootID": root_id,
                    "representedObjectCount": len(visible),
                    "center": center,
                    "size": size,
                }
            )
        if not 1 <= len(boxes) <= 64:
            raise ValueError("A selectable part requires 1–64 boxes.")
        total += len(boxes)
        part["selection"] = {"kind": "boxes", "boxes": boxes}
        evidence_parts.append(
            {
                "partID": part["partID"],
                "kind": "boxes",
                "boxCount": len(boxes),
                "clusters": clusters,
            }
        )
    if total > 128:
        raise ValueError("Catalog exceeds the 128-box interaction budget.")
    assert catalog["assetID"] == expected_asset and catalog["sha256"] == expected_digest
    write_json(args.catalog, catalog)
    write_json(
        args.evidence,
        {
            "schema": "astra-source-selection-proxies/v1",
            "sourceSHA256": source_sha,
            "assetID": expected_asset,
            "assetSHA256": expected_digest,
            "catalog": str(args.catalog.relative_to(ROOT)),
            "coordinates": "Prototype local coordinates: inverse(sourceRestTransform) applied to source mesh bounds.",
            "partCount": len(catalog["parts"]),
            "boxCount": total,
            "parts": evidence_parts,
            "geometryModified": False,
            "nativeSelectionVerified": False,
        },
    )
    print(
        json.dumps(
            {
                "catalog": str(args.catalog),
                "parts": len(catalog["parts"]),
                "boxes": total,
                "geometryModified": False,
            }
        ),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
