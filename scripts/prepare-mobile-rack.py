#!/usr/bin/env python3
"""Create the pinned rack's mobile USDZ without modifying its editable source.

Run with ordinary Python; it launches Blender's bundled bpy + OpenUSD runtime:
  python3 scripts/prepare-mobile-rack.py --blender /Applications/Blender.app/Contents/MacOS/Blender

Optional distance profile dependency: fast-simplification==0.1.13 in --python-deps.
No network access or runtime Blender is required once build dependencies exist. Geometry is processed
once per authored mesh; USD hierarchy, internal references, part IDs, transforms,
materials and stage coordinates are retained in a copy of the source layer.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import time
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INPUT_SHA256 = "aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba"
SOURCE_COMMIT = "051c9d954292438fc8419661aa91451367961d86"
PSU_MESH_NAMES = {"rack01_psu_06_mesh", "rack01_psu_06_mesh_001"}


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--blender", default="/Applications/Blender.app/Contents/MacOS/Blender")
    parser.add_argument("--python-deps", type=Path, default=ROOT / "runtime/processed-assets/python-deps", help="Directory containing pinned fast-simplification==0.1.13 (see processing README).")
    parser.add_argument("--input", type=Path, default=ROOT / "runtime/asset-source/datacenter-rack/models/lazy/rack-exterior.usdz")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--profile", choices=("conservative", "distance", "faithful"), default="conservative", help="faithful preserves all geometry and indexes identical normals; conservative and distance simplify geometry with visible fidelity loss.")
    parser.add_argument("--server-triangles", type=int, default=None, help="Triangle budget for the shared server mesh (18 visible uses).")
    parser.add_argument("--rack-ratio", type=float, default=0.20, help="Triangle fraction for rack meshes; labels and meshes below 1,000 triangles are retained.")
    parser.add_argument("--correct-psu6", action="store_true", help="Apply the independently reproduced pinned-source PSU6 parenting correction: world delta [0,+0.4,-1.908] metres.")
    parser.add_argument("--render-comparison", action="store_true", help="Render actual source and derivative geometry with identical Blender Workbench cameras.")
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    args = parser.parse_args(argv)
    if args.output is None:
        args.output = ROOT / ("runtime/processed-assets/rack-exterior-faithful-v2.usdz" if args.profile == "faithful" else "runtime/processed-assets/rack-exterior-mobile.usdz")
    if args.evidence is None:
        args.evidence = ROOT / ("evidence/mobile-rack-faithful-v2.json" if args.profile == "faithful" else "evidence/mobile-rack-processing.json")
    if args.server_triangles is None:
        args.server_triangles = 18000 if args.profile == "conservative" else 22000
    if not 0 < args.rack_ratio <= 1 or args.server_triangles < 1000:
        parser.error("--rack-ratio must be in (0,1] and --server-triangles >= 1000")
    if args.input.resolve() == args.output.resolve():
        parser.error("Source and derivative paths must differ.")
    return args


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(path):
    try:
        return str(path.resolve().relative_to(ROOT))
    except ValueError:
        return str(path.resolve())


def run():
    args = arguments()
    try:
        import bpy
    except ImportError:
        command = [args.blender, "--background", "--factory-startup", "--python-exit-code", "1", "--python", str(Path(__file__).resolve()), "--", *sys.argv[1:]]
        return subprocess.run(command, check=False).returncode
    from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, UsdUtils, Vt
    from mathutils import Vector
    from mathutils.bvhtree import BVHTree
    import numpy as np
    sys.path.insert(0, str(args.python_deps.resolve()))
    fast_simplification = None
    if args.profile == "distance":
        try:
            import fast_simplification
        except ImportError as error:
            raise RuntimeError("Missing fast-simplification==0.1.13. Install into --python-deps using Blender bundled python -m pip install --no-deps --target <directory> fast-simplification==0.1.13") from error
        if fast_simplification.__version__ != "0.1.13":
            raise ValueError("This recipe requires fast-simplification==0.1.13.")

    started = time.monotonic()
    actual_sha = sha256(args.input)
    if actual_sha != INPUT_SHA256:
        raise ValueError(f"Input SHA256 mismatch. Expected {INPUT_SHA256}, got {actual_sha}; reassess source geometry before changing the pin.")
    if args.profile == "faithful":
        return prepare_faithful(args, started, bpy, np)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    work_layer = args.output.with_suffix(".usdc")
    source = Usd.Stage.Open(str(args.input))
    source.GetRootLayer().Export(str(work_layer))
    stage = Usd.Stage.Open(str(work_layer))

    def mesh_prims(s):
        return [p for p in s.TraverseAll() if p.IsA(UsdGeom.Mesh)]

    def signature(s):
        result = {}
        for p in s.TraverseAll():
            if p.IsA(UsdGeom.Xform):
                result[str(p.GetPath())] = {
                    "part_id": p.GetAttribute("userProperties:part_id").Get(),
                    "xform": str(UsdGeom.Xformable(p).GetLocalTransformation()),
                    "instanceable": p.IsInstanceable(),
                    "references": str(p.GetMetadata("references")),
                }
        return result

    source_signature = signature(source)
    source_materials = {str(p.GetPath()) for p in source.TraverseAll() if p.IsA(UsdShade.Material)}
    before_metrics = stage_metrics(source)
    rows = []
    corrections = []
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    for prim in mesh_prims(stage):
        usdmesh = UsdGeom.Mesh(prim)
        path = str(prim.GetPath())
        points = np.asarray(usdmesh.GetPointsAttr().Get(), dtype=np.float32).copy()
        original_points = points.copy()
        counts = list(usdmesh.GetFaceVertexCountsAttr().Get())
        indices = list(usdmesh.GetFaceVertexIndicesAttr().Get())
        faces, offset = [], 0
        for count in counts:
            faces.append(indices[offset:offset + count])
            offset += count
        source_triangles = sum(max(0, n - 2) for n in counts)
        # GetAllChildren includes the undefined, referenced source prototype.
        subsets = [UsdGeom.Subset(p) for p in prim.GetAllChildren() if p.IsA(UsdGeom.Subset)]
        material_subsets = [s for s in subsets if s.GetFamilyNameAttr().Get() == "materialBind"]
        face_material = np.zeros(len(faces), dtype=np.int32)
        for i, subset in enumerate(material_subsets, start=1):
            face_material[np.asarray(subset.GetIndicesAttr().Get(), dtype=np.int32)] = i
        if any(s not in material_subsets for s in subsets):
            raise ValueError(f"Unsupported non-material subset at {path}; must preserve its semantic indices explicitly.")
        mesh = bpy.data.meshes.new(prim.GetName())
        mesh.from_pydata(points.tolist(), [], faces)
        mesh.update()
        obj = bpy.data.objects.new(prim.GetName(), mesh)
        bpy.context.collection.objects.link(obj)
        bpy.context.view_layer.objects.active = obj
        for i in range(len(material_subsets) + 1):
            mesh.materials.append(bpy.data.materials.new(f"{prim.GetName()}_{i}"))
        mesh.polygons.foreach_set("material_index", face_material)
        # Preserve the author's corner normals where the modifier can interpolate
        # them; output explicit corner normals so renderer smoothing is stable.
        normals = usdmesh.GetNormalsAttr().Get()
        interpolation = usdmesh.GetNormalsInterpolation()
        if normals:
            n = np.asarray(normals, dtype=np.float32)
            if interpolation == UsdGeom.Tokens.vertex:
                n = n[np.asarray(indices)]
            if len(n) == len(mesh.loops):
                mesh.polygons.foreach_set("use_smooth", [True] * len(faces))
                mesh.normals_split_custom_set(n.tolist())
        is_server = "/prototypes/" in path
        preserve = source_triangles < 1000 or "labels" in prim.GetName()
        target = source_triangles if preserve else min(source_triangles, args.server_triangles if is_server else max(512, int(source_triangles * args.rack_ratio)))
        if is_server and args.profile == "distance" and target < source_triangles:
            simplified = simplify_server(mesh, target, fast_simplification, np)
            obj.data = simplified
        elif target < source_triangles:
            weld = obj.modifiers.new("Join coincident CAD vertices", "WELD")
            weld.merge_threshold = 0.00001
            bpy.ops.object.modifier_apply(modifier=weld.name)
            dissolve = obj.modifiers.new("Dissolve coplanar faces", "DECIMATE")
            dissolve.decimate_type = "DISSOLVE"
            dissolve.angle_limit = math.radians(0.5)
            dissolve.delimit = {"MATERIAL", "NORMAL"}
            bpy.ops.object.modifier_apply(modifier=dissolve.name)
            obj.data.calc_loop_triangles()
            planar_triangles = len(obj.data.loop_triangles)
            if planar_triangles > target:
                decimate = obj.modifiers.new("Mobile triangle budget", "DECIMATE")
                decimate.decimate_type = "COLLAPSE"
                decimate.ratio = target / planar_triangles
                decimate.use_collapse_triangulate = True
                bpy.ops.object.modifier_apply(modifier=decimate.name)
        result = obj.data
        result.calc_loop_triangles()
        output_points = np.empty(len(result.vertices) * 3, dtype=np.float32)
        result.vertices.foreach_get("co", output_points)
        output_points = output_points.reshape((-1, 3))
        output_indices, output_normals, output_materials = [], [], []
        corner_normals = result.corner_normals
        for tri in result.loop_triangles:
            output_indices.extend(tri.vertices)
            output_normals.extend(tuple(corner_normals[i].vector) for i in tri.loops)
            output_materials.append(result.polygons[tri.polygon_index].material_index)
        output_counts = [3] * len(output_materials)
        geometry_error = sample_error(original_points, faces, output_points, output_indices, BVHTree, Vector, np)
        # Source reproducer evidence documents this exact double-parenting offset.
        if args.correct_psu6 and prim.GetName() in PSU_MESH_NAMES:
            world_delta = Gf.Vec3d(0, 0.4, -1.908)
            transform = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default())
            local_delta = transform.GetInverse().TransformDir(world_delta)
            output_points += np.asarray(local_delta, dtype=np.float32)
            corrections.append({"mesh": path, "world_translation_m": list(world_delta), "reason": "Pinned source service-child reparenting used a stale dependency graph; verified by independently rerunning rack_frame.py with and without view_layer.update()."})
        usdmesh.GetPointsAttr().Set(Vt.Vec3fArray.FromNumpy(output_points))
        usdmesh.GetFaceVertexCountsAttr().Set(output_counts)
        usdmesh.GetFaceVertexIndicesAttr().Set(output_indices)
        usdmesh.GetNormalsAttr().Set(Vt.Vec3fArray(output_normals))
        usdmesh.SetNormalsInterpolation(UsdGeom.Tokens.faceVarying)
        usdmesh.GetSubdivisionSchemeAttr().Set(UsdGeom.Tokens.none)
        usdmesh.GetExtentAttr().Set([Gf.Vec3f(*output_points.min(axis=0).tolist()), Gf.Vec3f(*output_points.max(axis=0).tolist())])
        # This pinned exterior contains no textures. Its cable UVs are unused;
        # retaining old face-varying arrays after topology changes would be invalid.
        removed_uv = []
        for name in [a.GetName() for a in prim.GetAuthoredAttributes() if a.GetName().startswith("primvars:")]:
            if name not in {"primvars:st", "primvars:st:indices"}:
                raise ValueError(f"Unexpected primvar {name} at {path}; reassess interpolation before processing.")
            prim.RemoveProperty(name)
            removed_uv.append(name)
        for i, subset in enumerate(material_subsets, start=1):
            kept = [j for j, material in enumerate(output_materials) if material == i]
            if not kept and subset.GetIndicesAttr().Get():
                raise ValueError(f"Decimation removed the complete material region {subset.GetPath()}.")
            subset.GetIndicesAttr().Set(kept)
        row = {"path": path, "shared_server_prototype": is_server, "source_vertices": len(points), "source_faces": len(faces), "source_triangle_equivalents": source_triangles, "output_vertices": len(output_points), "output_triangles": len(output_materials), "requested_triangle_budget": target, "material_subsets_preserved": len(material_subsets), "removed_unused_uv_attributes": removed_uv, "sampled_surface_error_mm": geometry_error}
        rows.append(row)
        print(f"MOBILE_MESH {prim.GetName()} {source_triangles} -> {len(output_materials)} triangles", flush=True)
        bpy.data.objects.remove(obj, do_unlink=True)
        bpy.data.meshes.remove(result)
        if mesh != result and mesh.users == 0:
            bpy.data.meshes.remove(mesh)

    if signature(stage) != source_signature:
        raise AssertionError("Semantic hierarchy, transforms, or instance references changed.")
    if {str(p.GetPath()) for p in stage.TraverseAll() if p.IsA(UsdShade.Material)} != source_materials:
        raise AssertionError("Material definitions changed.")
    server_ids = sorted(v["part_id"] for v in source_signature.values() if v["part_id"] and len(v["part_id"].split(".")) == 2 and v["part_id"].startswith("rack01.server"))
    if server_ids != [f"rack01.server{i:02}" for i in range(1, 19)]:
        raise AssertionError("Expected all 18 independent server roots.")
    # Export to a fresh crate; saving modified input in place leaves obsolete
    # geometry blocks in USDC and can make the mobile package larger.
    compact_layer = work_layer.with_name(work_layer.stem + "-compact.usdc")
    stage.GetRootLayer().Export(str(compact_layer))
    if args.output.exists():
        args.output.unlink()
    if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(compact_layer)), str(args.output)):
        raise RuntimeError("USDZ packaging failed.")
    canonicalize_zip_timestamps(args.output)
    reopened = Usd.Stage.Open(str(args.output))
    if signature(reopened) != source_signature:
        raise AssertionError("USDZ round trip changed semantic hierarchy or references.")
    after_metrics = stage_metrics(reopened)
    evidence = {
        "schema": "astra.mobile-rack-processing.v1",
        "packaging": {"zip_timestamp": "1980-01-01 00:00:00", "reason": "Canonical ZIP metadata makes hashes independent of wall-clock build time; entry offsets and content remain unchanged."},
        "source": {"path": relative(args.input), "sha256": actual_sha, "bytes": args.input.stat().st_size, "repository": "https://github.com/abharw/astra2026", "commit": SOURCE_COMMIT, **before_metrics},
        "derivative": {"path": relative(args.output), "sha256": sha256(args.output), "bytes": args.output.stat().st_size, **after_metrics},
        "toolchain": {"blender": bpy.app.version_string, "blender_build_hash": bpy.app.build_hash.decode(), "openusd": ".".join(str(x) for x in Usd.GetVersion()), "fast_simplification": fast_simplification.__version__ if fast_simplification else None, "pipeline": relative(Path(__file__)), "pipeline_sha256": sha256(Path(__file__))},
        "settings": {"profile": args.profile, "server_algorithm": "fast-simplification per material region, flat normals from resulting geometry" if args.profile == "distance" else "Blender Weld + Decimate; topology limits may prevent reaching the requested budget", "rack_algorithm": "Blender Weld + Decimate", "server_triangle_budget": args.server_triangles, "rack_triangle_ratio": args.rack_ratio, "planar_dissolve_angle_degrees": 0.5, "coincident_vertex_weld_m": 0.00001, "preserve_labels": True, "preserve_meshes_below_triangles": 1000, "correct_psu6": args.correct_psu6},
        "verification": {"source_sha256_unchanged": sha256(args.input) == actual_sha, "semantic_roots_transforms_and_references_unchanged": True, "material_definitions_preserved": True, "independent_server_ids": server_ids, "usdz_reopened": True},
        "source_corrections": corrections,
        "source_correction_evidence": "evidence/asset-intake.json and evidence/rack-psu-offset-reproduction.py",
        "meshes": rows,
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "limits": ["Exterior distance LOD only; not metrology geometry.", "Surface errors are deterministic vertex samples before the separately documented PSU correction, not a Hausdorff-distance proof.", "Mobile LOD contracts fine perforations and shows visible faceting on close inspection; it is intended for a whole-rack view.", "Blender visual comparison does not establish iPhone or headset frame rate.", "The detailed mechanical, motherboard, memory, and processor-study Blender libraries are not yet converted to native detail assets."]
    }
    args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
    print("MOBILE_RACK_READY", json.dumps({"path": str(args.output.resolve()), "bytes": args.output.stat().st_size, "expanded_triangles": after_metrics["visible_expanded_triangle_equivalents"], "evidence": str(args.evidence)}), flush=True)
    if args.render_comparison:
        render_comparison(args.input, args.output, args.output.parent / (args.output.stem + "-comparison"))
    return 0


def prepare_faithful(args, started, bpy, np):
    """Lossless normal storage optimization; geometry and shading stay authored.

    Unlike decimation, indexing repeated normals cannot close perforations or
    warp a panel. The expanded normal array is checked value-for-value after USDZ
    packaging. The optional independently reproduced PSU correction is the only
    allowed point change. Device import remains a separate compatibility gate.
    """
    from pxr import Gf, Sdf, Usd, UsdGeom, UsdUtils, Vt
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    source = Usd.Stage.Open(str(args.input))
    work_layer = args.output.with_suffix(".usdc")
    source.GetRootLayer().Export(str(work_layer))
    stage = Usd.Stage.Open(str(work_layer))
    rows, corrections = [], []
    for prim in stage.TraverseAll():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        source_normals = mesh.GetNormalsAttr().Get()
        if source_normals is not None:
            normals = np.asarray(source_normals, dtype=np.float32)
            if len(normals):
                values, indices = np.unique(normals, axis=0, return_inverse=True)
                indexed = len(values) * 12 + len(indices) * 4 < len(normals) * 12
                if indexed:
                    var = UsdGeom.PrimvarsAPI(prim).CreatePrimvar("normals", Sdf.ValueTypeNames.Normal3fArray, mesh.GetNormalsInterpolation())
                    var.Set(Vt.Vec3fArray.FromNumpy(values))
                    var.SetIndices(Vt.IntArray.FromNumpy(indices.astype(np.int32)))
                    prim.RemoveProperty("normals")
                    if not np.array_equal(normals, np.asarray(var.ComputeFlattened())):
                        raise AssertionError(f"Indexing changed normals at {prim.GetPath()}")
                rows.append({"path": str(prim.GetPath()), "normal_elements_before": len(normals), "unique_normal_elements": len(values), "indexed_normals": indexed})
        if args.correct_psu6 and prim.GetName() in PSU_MESH_NAMES:
            points = np.asarray(mesh.GetPointsAttr().Get(), dtype=np.float32).copy()
            world_delta = Gf.Vec3d(0, 0.4, -1.908)
            transform = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(Usd.TimeCode.Default())
            points += np.asarray(transform.GetInverse().TransformDir(world_delta), dtype=np.float32)
            mesh.GetPointsAttr().Set(Vt.Vec3fArray.FromNumpy(points))
            mesh.GetExtentAttr().Set([Gf.Vec3f(*points.min(axis=0).tolist()), Gf.Vec3f(*points.max(axis=0).tolist())])
            corrections.append({"mesh": str(prim.GetPath()), "world_translation_m": list(world_delta)})
    compact_layer = work_layer.with_name(work_layer.stem + "-compact.usdc")
    stage.GetRootLayer().Export(str(compact_layer))
    if args.output.exists():
        args.output.unlink()
    if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(str(compact_layer)), str(args.output)):
        raise RuntimeError("USDZ packaging failed.")
    canonicalize_zip_timestamps(args.output)
    reopened = Usd.Stage.Open(str(args.output))
    for row in rows:
        original = UsdGeom.Mesh(source.GetPrimAtPath(row["path"]))
        processed = UsdGeom.Mesh(reopened.GetPrimAtPath(row["path"]))
        var = UsdGeom.PrimvarsAPI(processed).GetPrimvar("normals")
        normal_values = var.ComputeFlattened() if var else processed.GetNormalsAttr().Get()
        if not np.array_equal(np.asarray(original.GetNormalsAttr().Get()), np.asarray(normal_values)):
            raise AssertionError(f"Packaged normals changed at {row['path']}")
        for getter in ("GetFaceVertexCountsAttr", "GetFaceVertexIndicesAttr"):
            if not np.array_equal(np.asarray(getattr(original, getter)().Get()), np.asarray(getattr(processed, getter)().Get())):
                raise AssertionError(f"Topology changed at {row['path']}")
        if not (args.correct_psu6 and processed.GetPrim().GetName() in PSU_MESH_NAMES):
            if not np.array_equal(np.asarray(original.GetPointsAttr().Get()), np.asarray(processed.GetPointsAttr().Get())):
                raise AssertionError(f"Positions changed at {row['path']}")
    if sha256(args.input) != INPUT_SHA256:
        raise AssertionError("Source changed during preparation.")
    metrics = stage_metrics(reopened)
    evidence = {
        "schema": "astra.mobile-rack-processing.v2",
        "source": {"path": relative(args.input), "sha256": INPUT_SHA256, "bytes": args.input.stat().st_size, "repository": "https://github.com/abharw/astra2026", "commit": SOURCE_COMMIT, **stage_metrics(source)},
        "derivative": {"path": relative(args.output), "sha256": sha256(args.output), "bytes": args.output.stat().st_size, **metrics},
        "toolchain": {"blender": bpy.app.version_string, "blender_build_hash": bpy.app.build_hash.decode(), "openusd": ".".join(str(x) for x in Usd.GetVersion()), "pipeline": relative(Path(__file__)), "pipeline_sha256": sha256(Path(__file__))},
        "settings": {"profile": "faithful", "geometry_simplification": False, "normals": "Exact unique float32 values with indexed primvars:normals where smaller; original normal interpolation retained", "correct_psu6": args.correct_psu6, "zip_timestamp": "1980-01-01 00:00:00"},
        "verification": {"source_sha256_unchanged": True, "topology_arrays_identical": True, "points_identical_except_documented_psu6_correction": True, "expanded_authored_normals_identical": True, "usdz_reopened": True},
        "source_corrections": corrections,
        "source_correction_evidence": "evidence/asset-intake.json and evidence/rack-psu-offset-reproduction.py",
        "meshes": rows, "elapsed_seconds": round(time.monotonic() - started, 3),
        "limits": ["Reduces serialized bytes, not expanded triangle count or proven GPU cost.", "Indexed normals require separate RealityKit import and visual acceptance.", "Retains the source exterior only; detailed Blender interior libraries are not exported.", "Blender comparison is not a device frame-rate measurement."],
    }
    args.evidence.write_text(json.dumps(evidence, indent=2) + "\n")
    print("MOBILE_RACK_READY", json.dumps({"path": str(args.output.resolve()), "bytes": args.output.stat().st_size, "expanded_triangles": metrics["visible_expanded_triangle_equivalents"], "evidence": str(args.evidence)}), flush=True)
    if args.render_comparison:
        render_comparison(args.input, args.output, args.output.parent / (args.output.stem + "-comparison"))
    return 0


def simplify_server(mesh, target, simplifier, np):
    """Simplify each material region independently; retain small black details.

    Blender's topology-preserving edge collapse bottoms out on the thousands of
    holes in this source CAD surface. The pinned quadric simplifier can contract
    those holes for the distance LOD. It never merges server identities/materials.
    """
    import bpy
    from mathutils import Vector
    from mathutils.bvhtree import BVHTree
    mesh.calc_loop_triangles()
    points = np.asarray([v.co[:] for v in mesh.vertices], dtype=np.float64)
    triangles = np.asarray([t.vertices[:] for t in mesh.loop_triangles], dtype=np.int32)
    material = np.asarray([mesh.polygons[t.polygon_index].material_index for t in mesh.loop_triangles])
    groups = [(int(i), triangles[material == i]) for i in np.unique(material)]
    reserved = sum(len(faces) for _, faces in groups if len(faces) <= 4096)
    remaining_source = sum(len(faces) for _, faces in groups if len(faces) > 4096)
    vertices_out, triangles_out, materials_out = [], [], []
    vertex_offset = 0
    for slot, faces in groups:
        if len(faces) <= 4096:
            used, compact = np.unique(faces, return_inverse=True)
            region_points, region_faces = points[used], compact.reshape((-1, 3))
        else:
            region_target = max(512, int((target - reserved) * len(faces) / remaining_source))
            region_points, region_faces = simplifier.simplify(points, faces, target_count=region_target, agg=7.0)
        vertices_out.extend(region_points.tolist())
        triangles_out.extend((region_faces + vertex_offset).tolist())
        materials_out.extend([slot] * len(region_faces))
        vertex_offset += len(region_points)
    result = bpy.data.meshes.new(mesh.name + "_mobile")
    result.from_pydata(vertices_out, [], triangles_out)
    for material_slot in mesh.materials:
        result.materials.append(material_slot)
    result.polygons.foreach_set("material_index", materials_out)
    result.polygons.foreach_set("use_smooth", [False] * len(materials_out))
    result.update()
    # The aggressive exterior LOD changes perforation topology. Source normals
    # from tiny hole walls transferred to a large new face create false crumpled
    # highlights; use normals of the actual resulting surface instead.
    return result


def canonicalize_zip_timestamps(path):
    """Normalize ZIP metadata without changing USDZ 64-byte entry alignment."""
    data = bytearray(path.read_bytes())
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        central = archive.start_dir
    dos_epoch = struct.pack("<HH", 0, 33)  # midnight, 1980-01-01
    for entry in entries:
        assert data[entry.header_offset:entry.header_offset + 4] == b"PK\x03\x04"
        data[entry.header_offset + 10:entry.header_offset + 14] = dos_epoch
        assert data[central:central + 4] == b"PK\x01\x02"
        data[central + 12:central + 16] = dos_epoch
        name_size, extra_size, comment_size = struct.unpack_from("<HHH", data, central + 28)
        central += 46 + name_size + extra_size + comment_size
    path.write_bytes(data)


def stage_metrics(stage):
    from pxr import Usd, UsdGeom, UsdShade
    authored = [p for p in stage.TraverseAll() if p.IsA(UsdGeom.Mesh)]
    visible = [p for p in Usd.PrimRange.Stage(stage, Usd.TraverseInstanceProxies()) if p.IsA(UsdGeom.Mesh)]
    def triangles(prim):
        return sum(max(0, n - 2) for n in UsdGeom.Mesh(prim).GetFaceVertexCountsAttr().Get())
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), [UsdGeom.Tokens.default_, UsdGeom.Tokens.render])
    bounds = cache.ComputeWorldBound(stage.GetDefaultPrim()).ComputeAlignedRange()
    return {"up_axis": UsdGeom.GetStageUpAxis(stage), "meters_per_unit": UsdGeom.GetStageMetersPerUnit(stage), "authored_meshes": len(authored), "authored_vertices": sum(len(UsdGeom.Mesh(p).GetPointsAttr().Get()) for p in authored), "authored_triangle_equivalents": sum(triangles(p) for p in authored), "visible_mesh_occurrences": len(visible), "visible_expanded_triangle_equivalents": sum(triangles(p) for p in visible), "instances": len([p for p in stage.Traverse() if p.IsInstance()]), "prototypes": len(stage.GetPrototypes()), "materials": len([p for p in stage.TraverseAll() if p.IsA(UsdShade.Material)]), "material_subsets": len([p for p in stage.TraverseAll() if p.IsA(UsdGeom.Subset)]), "world_bounds_m": [list(bounds.GetMin()), list(bounds.GetMax())]}


def sample_error(original_points, original_faces, output_points, output_indices, BVHTree, Vector, np):
    source_tree = BVHTree.FromPolygons([Vector(p) for p in original_points], original_faces)
    output_faces = np.asarray(output_indices).reshape((-1, 3)).tolist()
    output_tree = BVHTree.FromPolygons([Vector(p) for p in output_points], output_faces, all_triangles=True)
    result = {}
    for label, points, target in [("source_to_output", original_points, output_tree), ("output_to_source", output_points, source_tree)]:
        samples = points[np.linspace(0, len(points) - 1, min(2048, len(points)), dtype=int)]
        distances = [target.find_nearest(Vector(p))[3] * 1000 for p in samples]
        result[label] = {"samples": len(distances), "p95": round(float(np.percentile(distances, 95)), 5), "p99": round(float(np.percentile(distances, 99)), 5), "max": round(float(max(distances)), 5)}
    return result


def render_comparison(source, derivative, directory):
    directory.mkdir(parents=True, exist_ok=True)
    import bpy
    from mathutils import Vector
    for label, path in [("source", source), ("mobile", derivative)]:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.ops.wm.usd_import(filepath=str(path))
        scene = bpy.context.scene
        scene.render.engine = "BLENDER_WORKBENCH"
        scene.render.resolution_x = 1000
        scene.render.resolution_y = 1200
        scene.render.resolution_percentage = 100
        scene.render.image_settings.file_format = "PNG"
        scene.world = bpy.data.worlds.new("Preview world")
        shading = scene.display.shading
        shading.light = "STUDIO"
        shading.studiolight_rotate_z = math.radians(25)
        shading.color_type = "MATERIAL"
        shading.show_shadows = True
        shading.show_cavity = True
        shading.cavity_type = "BOTH"
        shading.background_type = "WORLD"
        scene.world.color = (0.16, 0.16, 0.16)
        for view, camera_position in [("front", (3.5, -6, 3.2)), ("rear", (-3.5, 6, 3.2))]:
            camera_data = bpy.data.cameras.new("Comparison camera")
            camera = bpy.data.objects.new("Comparison camera", camera_data)
            scene.collection.objects.link(camera)
            camera.location = camera_position
            target = Vector((0, 0, 1.15))
            camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
            camera_data.type = "ORTHO"
            camera_data.ortho_scale = 2.9
            scene.camera = camera
            scene.render.filepath = str(directory / f"rack-{label}-{view}.png")
            bpy.ops.render.render(write_still=True)
            bpy.data.objects.remove(camera, do_unlink=True)


if __name__ == "__main__":
    raise SystemExit(run())
