#!/usr/bin/env python3
"""Compile configured Blender groups into an independently addressable asset pack.

This is an offline build step. It never changes the .blend source, downloads
assets, or invents geometry. Run with ordinary Python; Blender supplies bpy and
OpenUSD. The recipe supplies hierarchy membership, semantic descriptions and budgets.
No domain-specific part names or intent routing are built into the compiler.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def arguments():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--recipe",
        type=Path,
        default=ROOT / "assets/imported-rack/teaching-groups.json",
    )
    parser.add_argument(
        "--blender", default="/Applications/Blender.app/Contents/MacOS/Blender"
    )
    parser.add_argument(
        "--input", type=Path, default=ROOT / ".local/detail-source/parts-library.blend"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / ".local/processed-assets/server-teaching.usdz",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=ROOT / "assets/imported-rack/detail-levels.json",
    )
    parser.add_argument(
        "--evidence", type=Path, default=ROOT / "docs/evidence/server-detail-processing.json"
    )
    parser.add_argument(
        "--index",
        type=Path,
        default=ROOT / ".local/processed-assets/server-teaching-source-index.json",
    )
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else sys.argv[1:]
    return parser.parse_args(argv)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(path):
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path.resolve())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def run():
    args = arguments()
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
    import bmesh
    import numpy as np
    from mathutils import Matrix, Vector
    from pxr import Usd, UsdGeom

    started = time.monotonic()
    recipe = json.loads(args.recipe.read_text())
    source_sha = recipe["source"]["sha256"]
    collections = recipe["collections"]
    groups = {row["id"]: row for row in recipe["groups"]}
    if len(groups) != len(recipe["groups"]) or not groups:
        raise ValueError("Group IDs must be nonempty and unique.")
    if recipe["fallbackGroup"] not in groups:
        raise ValueError("Fallback group is missing.")
    if (
        recipe["coordinates"].get("units") != "meters"
        or recipe["coordinates"].get("sourceUpAxis") != "Z"
    ):
        raise ValueError(
            "This Blender compiler accepts metre-based, Z-up source recipes."
        )
    if any(
        group not in groups for group in recipe.get("collectionFallbacks", {}).values()
    ):
        raise ValueError("A collection fallback refers to a missing group.")
    if digest(args.input) != source_sha:
        raise ValueError(
            "Unexpected source library digest; review the source before changing the pin."
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    with bpy.data.libraries.load(str(args.input), link=True) as (available, requested):
        if not set(collections).issubset(available.collections):
            raise ValueError("The pinned detail collections are missing.")
        requested.collections = list(collections)
    for collection in requested.collections:
        bpy.context.scene.collection.children.link(collection)
    bpy.context.view_layer.update()
    print("SOURCE_LOADED", round(time.monotonic() - started, 3), flush=True)

    membership = defaultdict(set)
    for collection in requested.collections:
        for obj in collection.all_objects:
            membership[obj].add(collection.name)
    source_objects = list(membership)
    source_poses = {obj: obj.matrix_world.copy() for obj in source_objects}
    source_sizes = {obj: tuple(obj.dimensions) for obj in source_objects}
    # Evaluating a temporary decimator with the entire source scene linked
    # repeatedly rebuilds a huge dependency graph. Snapshot its transforms once,
    # then evaluate only local temporary objects and the small compiled output.
    for collection in requested.collections:
        bpy.context.scene.collection.children.unlink(collection)
    bpy.context.view_layer.update()
    outputs = bpy.data.collections.new("Compiled asset groups")
    bpy.context.scene.collection.children.link(outputs)
    temporary = bpy.data.collections.new("Compilation temporary")
    bpy.context.scene.collection.children.link(temporary)

    def ancestry_ids(obj):
        ids = set()
        while obj:
            identifier = str(obj.get("part_id", ""))
            if identifier:
                ids.add(identifier)
            obj = obj.parent
        return ids

    def group_for(obj):
        ancestors = ancestry_ids(obj)
        for group, definition in groups.items():
            if set(definition.get("ancestorPartIDs", [])) & ancestors:
                return group
        for collection, group in recipe.get("collectionFallbacks", {}).items():
            if collection in membership[obj]:
                return group
        return recipe["fallbackGroup"]

    material_cache = {}

    def preview_material(source):
        # Output is deliberately untextured PBR. Embedded/referenced fabrication
        # images are not copied without a separate texture-budget review.
        name = source.name if source else "Unspecified material"
        if name in material_cache:
            return material_cache[name]
        material = bpy.data.materials.new("Teaching " + name)
        material.use_nodes = True
        shader = material.node_tree.nodes.get("Principled BSDF")
        color = tuple(source.diffuse_color) if source else (0.45, 0.45, 0.45, 1.0)
        metallic, roughness = 0.0, 0.65
        if source and source.use_nodes:
            original = next(
                (
                    node
                    for node in source.node_tree.nodes
                    if node.type == "BSDF_PRINCIPLED"
                ),
                None,
            )
            if original:
                if not original.inputs["Base Color"].is_linked:
                    color = tuple(original.inputs["Base Color"].default_value)
                metallic = original.inputs["Metallic"].default_value
                roughness = original.inputs["Roughness"].default_value
        shader.inputs["Base Color"].default_value = color
        shader.inputs["Metallic"].default_value = metallic
        shader.inputs["Roughness"].default_value = roughness
        material.diffuse_color = color
        material_cache[name] = material
        return material

    buckets = {key: [] for key in groups}
    omitted = Counter()
    for obj in source_objects:
        if obj.type not in {"MESH", "CURVE", "FONT"}:
            continue
        group = group_for(obj)
        part_id = str(obj.get("part_id", obj.name))
        skip = False
        for exclusion in recipe.get("exclusions", []):
            if exclusion.get("group", group) != group:
                continue
            if (
                "partIDContains" in exclusion
                and exclusion["partIDContains"] not in part_id
            ):
                continue
            if (
                "maximumDimensionBelowMeters" in exclusion
                and max(source_sizes[obj]) >= exclusion["maximumDimensionBelowMeters"]
            ):
                continue
            omitted[exclusion["reason"]] += 1
            skip = True
            break
        if skip:
            continue
        buckets[group].append(obj)

    records = []
    source_index = {}
    for key, objects in buckets.items():
        if not objects:
            raise ValueError(f"No geometry resolved for teaching group {key}.")
        definition = groups[key]
        label, description, representation, budget = (
            definition[field]
            for field in ("name", "description", "representation", "triangleBudget")
        )
        vertex_arrays, face_arrays, material_arrays = [], [], []
        group_materials, local_materials = [], {}
        vertex_offset, source_triangles = 0, 0
        source_rows = []
        for number, obj in enumerate(objects):
            world = source_poses[obj]
            if obj.type == "MESH" and not obj.modifiers:
                mesh = obj.data.copy()
            else:
                evaluation = obj.copy()
                evaluation.parent = None
                evaluation.matrix_world = Matrix.Identity(4)
                temporary.objects.link(evaluation)
                dependencies = bpy.context.evaluated_depsgraph_get()
                mesh = bpy.data.meshes.new_from_object(
                    evaluation.evaluated_get(dependencies), depsgraph=dependencies
                )
                bpy.data.objects.remove(evaluation, do_unlink=True)
            mesh.calc_loop_triangles()
            triangles = len(mesh.loop_triangles)
            if not triangles:
                bpy.data.meshes.remove(mesh)
                continue
            source_triangles += triangles
            source_rows.append(
                {
                    "partID": str(obj.get("part_id", obj.name)),
                    "blenderObject": obj.name,
                    "sourceTriangles": triangles,
                    "evidence": str(obj.get("evidence_level", "unspecified")),
                }
            )
            if triangles > 1200:
                bm = bmesh.new()
                bm.from_mesh(mesh)
                bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.000005)
                bmesh.ops.dissolve_limit(
                    bm,
                    angle_limit=0.01,
                    use_dissolve_boundaries=False,
                    verts=bm.verts,
                    edges=bm.edges,
                    delimit={"MATERIAL", "NORMAL"},
                )
                bm.to_mesh(mesh)
                bm.free()
                mesh.update()
                mesh.calc_loop_triangles()
                local_budget = (
                    5000
                    if max(source_sizes[obj]) > 0.3
                    else 1800 if max(source_sizes[obj]) > 0.05 else 500
                )
                if len(mesh.loop_triangles) > local_budget:
                    temp = bpy.data.objects.new("Compile mesh", mesh)
                    temporary.objects.link(temp)
                    modifier = temp.modifiers.new("Assembly overview", "DECIMATE")
                    modifier.ratio = local_budget / len(mesh.loop_triangles)
                    modifier.use_collapse_triangulate = True
                    deps = bpy.context.evaluated_depsgraph_get()
                    reduced = bpy.data.meshes.new_from_object(
                        temp.evaluated_get(deps), depsgraph=deps
                    )
                    bpy.data.objects.remove(temp, do_unlink=True)
                    bpy.data.meshes.remove(mesh)
                    mesh = reduced
            mesh.calc_loop_triangles()
            positions = np.empty(len(mesh.vertices) * 3, dtype=np.float64)
            mesh.vertices.foreach_get("co", positions)
            positions = positions.reshape((-1, 3))
            matrix = np.asarray(world)
            positions = positions @ matrix[:3, :3].T + matrix[:3, 3]
            indices = np.empty(len(mesh.loop_triangles) * 3, dtype=np.int32)
            mesh.loop_triangles.foreach_get("vertices", indices)
            indices = indices.reshape((-1, 3)) + vertex_offset
            polygon_indices = np.empty(len(mesh.loop_triangles), dtype=np.int32)
            mesh.loop_triangles.foreach_get("polygon_index", polygon_indices)
            polygon_materials = np.empty(len(mesh.polygons), dtype=np.int32)
            mesh.polygons.foreach_get("material_index", polygon_materials)
            slots = [slot.material for slot in obj.material_slots] or [None]
            remap = []
            for source_material in slots:
                material = preview_material(source_material)
                if material.name not in local_materials:
                    local_materials[material.name] = len(group_materials)
                    group_materials.append(material)
                remap.append(local_materials[material.name])
            face_materials = np.asarray(remap)[
                np.minimum(polygon_materials[polygon_indices], len(remap) - 1)
            ]
            vertex_arrays.append(positions)
            face_arrays.append(indices)
            material_arrays.append(face_materials)
            vertex_offset += len(positions)
            bpy.data.meshes.remove(mesh)
            if number and number % 100 == 0:
                print("GROUP_PROGRESS", key, number, len(objects), flush=True)
        positions = np.concatenate(vertex_arrays)
        faces = np.concatenate(face_arrays)
        face_materials = np.concatenate(material_arrays)
        minimum, maximum = positions.min(axis=0), positions.max(axis=0)
        center = (minimum + maximum) / 2
        mesh = bpy.data.meshes.new("detail_" + key + "_mesh")
        mesh.from_pydata((positions - center).tolist(), [], faces.tolist())
        for material in group_materials:
            mesh.materials.append(material)
        mesh.polygons.foreach_set("material_index", face_materials.astype(np.int32))
        mesh.update()
        obj = bpy.data.objects.new("detail_" + key, mesh)
        outputs.objects.link(obj)
        obj.location = Vector(center)
        obj["part_id"] = recipe["partIDPrefix"] + key
        obj["description"] = description
        obj["representation"] = representation
        obj["source_library_sha256"] = source_sha
        if len(faces) > budget:
            bpy.context.view_layer.objects.active = obj
            modifier = obj.modifiers.new("Teaching group triangle budget", "DECIMATE")
            modifier.ratio = budget / len(faces)
            modifier.use_collapse_triangulate = True
            bpy.ops.object.modifier_apply(modifier=modifier.name)
        obj.data.calc_loop_triangles()
        final_triangles = len(obj.data.loop_triangles)
        actual = np.array([tuple(obj.matrix_world @ Vector(p)) for p in obj.bound_box])
        # The scene update below is required after assigning object.location.
        bpy.context.view_layer.update()
        actual = np.array([tuple(obj.matrix_world @ Vector(p)) for p in obj.bound_box])
        row = {
            "partID": recipe["partIDPrefix"] + key,
            "suffix": key,
            "entityName": obj.name,
            "parentTemplateID": recipe["templateID"],
            "name": label,
            "description": description,
            "representation": representation,
            "sourceObjectCount": len(source_rows),
            "sourceTriangleCount": source_triangles,
            "triangleCount": final_triangles,
            "requestedTriangleBudget": budget,
            "triangleBudgetMet": final_triangles <= budget,
            "sourceBoundsMeters": {
                "minimum": actual.min(axis=0).tolist(),
                "maximum": actual.max(axis=0).tolist(),
            },
            "sourceRestTransform": {
                "translation": center.tolist(),
                "rotation": [0, 0, 0, 1],
                "scale": [1, 1, 1],
            },
            "detailAvailable": "source_library_only",
            "loadState": "exported_not_registered",
        }
        records.append(row)
        source_index[row["partID"]] = source_rows
        print("GROUP_FINISHED", key, final_triangles, flush=True)

    bpy.context.scene.collection.children.unlink(temporary)
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1
    bpy.ops.object.select_all(action="DESELECT")
    for obj in outputs.objects:
        obj.select_set(True)
    raw_output = args.output.with_name(args.output.stem + "-unindexed.usdz")
    bpy.ops.wm.usd_export(
        filepath=str(raw_output),
        selected_objects_only=True,
        export_materials=True,
        export_textures_mode="KEEP",
        export_custom_properties=True,
        root_prim_path="/" + recipe["rootEntityName"],
        export_cameras=False,
        export_lights=False,
        export_animation=False,
    )
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from asset_usd import compact_normals

    storage_optimization = compact_normals(raw_output, args.output)
    stage = Usd.Stage.Open(str(args.output))
    usd_triangles = sum(
        sum(
            max(0, int(count) - 2)
            for count in UsdGeom.Mesh(prim).GetFaceVertexCountsAttr().Get()
        )
        for prim in stage.TraverseAll()
        if prim.IsA(UsdGeom.Mesh)
    )
    if usd_triangles != sum(row["triangleCount"] for row in records):
        raise ValueError("USD export changed the expected triangle count.")
    names = {str(prim.GetName()) for prim in stage.TraverseAll()}
    if not {row["entityName"] for row in records}.issubset(names):
        raise ValueError("USD export lost a semantic assembly root.")
    result_sha = digest(args.output)
    descriptor = {
        "assetID": "sha256:" + result_sha,
        "name": recipe.get("name", recipe["templateID"]),
        "description": recipe.get("description"),
        "sourceURL": args.output.resolve().as_uri(),
        "sha256": result_sha,
        "byteCount": args.output.stat().st_size,
        "uniqueTriangleCount": usd_triangles,
        "parts": [
            {
                "partID": row["partID"],
                "name": row["name"],
                "role": groups[row["suffix"]].get("role", row["suffix"]),
                "description": row["description"]
                + " Representation: "
                + row["representation"]
                + ".",
                "entityName": row["entityName"],
                "triangleCount": row["triangleCount"],
            }
            for row in records
        ],
    }
    write_json(args.output.with_suffix(".catalog.json"), descriptor)
    manifest = {
        "schema": "astra-asset-detail-levels/v1",
        "source": recipe["source"],
        "templateID": recipe["templateID"],
        "coordinates": recipe["coordinates"],
        "compiledAsset": {
            "assetID": descriptor["assetID"],
            "sha256": result_sha,
            "byteCount": descriptor["byteCount"],
            "triangleCount": usd_triangles,
            "buildOutput": relative(args.output),
            "delivery": "local_build_artifact",
            "nativeSubtreeLoading": "pending_integration",
        },
        "hierarchy": {
            "rootID": recipe["templateID"],
            "children": [row["partID"] for row in records],
            "selectionPolicy": "Choose the smallest existing subtree sufficient for the request. Geometry detail and semantic depth are independent.",
        },
        "parts": records,
        "limits": recipe.get("limits", [])
        + [
            "Output uses untextured PBR colors from source material values, not image maps.",
            "Physical frame rate, first-visible time and native subtree installation require device validation.",
        ],
    }
    write_json(args.manifest, manifest)
    write_json(
        args.index,
        {
            "schema": "astra-teaching-source-index/v1",
            "sourceSHA256": source_sha,
            "parts": source_index,
        },
    )
    evidence = {
        "schema": "astra-asset-group-build/v1",
        "sourceSHA256": source_sha,
        "sourceBytes": args.input.stat().st_size,
        "blenderVersion": bpy.app.version_string,
        "output": relative(args.output),
        "sha256": result_sha,
        "bytes": descriptor["byteCount"],
        "triangleCount": usd_triangles,
        "partCount": len(records),
        "omittedOverviewObjects": dict(omitted),
        "materialCount": len(material_cache),
        "exportedUpAxis": str(UsdGeom.GetStageUpAxis(stage)),
        "metersPerUnit": UsdGeom.GetStageMetersPerUnit(stage),
        "seconds": time.monotonic() - started,
        "sourceUnchanged": digest(args.input) == source_sha,
        "nativeLoadVerified": False,
        "storageOptimization": storage_optimization,
    }
    write_json(args.evidence, evidence)
    print(json.dumps(evidence), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
