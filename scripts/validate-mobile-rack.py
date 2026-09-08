"""Read-only comparison of raw and processed rack USDZ; run with Blender Python.

blender -b --factory-startup --python validate-mobile-rack.py -- source.usdz mobile.usdz
Validates structural/metadata and material-binding preservation and geometry domains.
This does not establish visual fidelity or actual device rendering performance.
"""

import json
import hashlib
from pathlib import Path
import sys
import zipfile

import numpy as np
from pxr import Gf, Usd, UsdGeom, UsdShade


GEOMETRY_PROPERTIES = {
    "points", "faceVertexCounts", "faceVertexIndices", "normals", "extent",
    "holeIndices", "cornerIndices", "cornerSharpnesses", "creaseIndices",
    "creaseLengths", "creaseSharpnesses",
}


def assert_same(a, b, context):
    assert a == b, f"{context}: source={a!r}, output={b!r}"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def attr_snapshot(attr):
    return {
        "type": str(attr.GetTypeName()),
        "value": str(attr.Get()),
        "timeSamples": [(time, str(attr.Get(time))) for time in attr.GetTimeSamples()],
        "connections": [str(path) for path in attr.GetConnections()],
        "metadata": str(attr.GetAllMetadata()),
    }


def authored_prims(stage):
    # Traverse() excludes the undefined /root/prototypes container.
    return {str(prim.GetPath()): prim for prim in stage.TraverseAll()}


def geometry_property(prim, name):
    return (
        prim.IsA(UsdGeom.Mesh) and (name in GEOMETRY_PROPERTIES or name.startswith("primvars:"))
    ) or (prim.IsA(UsdGeom.Subset) and name == "indices")


def material_subsets(mesh):
    return [UsdGeom.Subset(p) for p in mesh.GetPrim().GetAllChildren()
            if p.IsA(UsdGeom.Subset) and UsdGeom.Subset(p).GetFamilyNameAttr().Get() == "materialBind"]


def mesh_stats(prim):
    mesh = UsdGeom.Mesh(prim)
    points = np.array(mesh.GetPointsAttr().Get(), dtype=np.float64)
    counts = np.array(mesh.GetFaceVertexCountsAttr().Get(), dtype=np.int64)
    indices = np.array(mesh.GetFaceVertexIndicesAttr().Get(), dtype=np.int64)
    name = str(prim.GetPath())
    assert points.ndim == 2 and points.shape[1] == 3 and len(points), f"{name}: no valid points"
    assert np.isfinite(points).all(), f"{name}: nonfinite points"
    assert len(counts) and (counts >= 3).all(), f"{name}: invalid face vertex counts"
    assert int(counts.sum()) == len(indices), f"{name}: corner count mismatch"
    assert indices.min() >= 0 and indices.max() < len(points), f"{name}: vertex index out of bounds"

    extent = np.array(mesh.GetExtentAttr().Get(), dtype=np.float64)
    assert extent.shape == (2, 3), f"{name}: missing extent"
    assert np.allclose(extent[0], points.min(axis=0), atol=1e-5), f"{name}: stale minimum extent"
    assert np.allclose(extent[1], points.max(axis=0), atol=1e-5), f"{name}: stale maximum extent"

    domains = {
        "constant": 1, "uniform": len(counts), "vertex": len(points),
        "varying": len(points), "faceVarying": len(indices),
    }
    normals = mesh.GetNormalsAttr().Get()
    if normals is not None:
        assert len(normals) == domains[str(mesh.GetNormalsInterpolation())], f"{name}: normals domain mismatch"
        assert np.isfinite(np.asarray(normals)).all(), f"{name}: nonfinite normals"

    for var in UsdGeom.PrimvarsAPI(prim).GetPrimvars():
        value = var.Get()
        if value is None:
            continue
        interpolation = str(var.GetInterpolation())
        if interpolation not in domains:
            raise AssertionError(f"{name}: unsupported {var.GetName()} interpolation {interpolation}")
        expected = domains[interpolation]
        element_size = var.GetElementSize()
        if var.IsIndexed():
            var_indices = np.asarray(var.GetIndices(), dtype=np.int64)
            assert len(var_indices) == expected, f"{name}: {var.GetName()} index domain mismatch"
            assert len(var_indices) and var_indices.min() >= 0, f"{name}: invalid primvar index"
            assert var_indices.max() < len(value) // element_size, f"{name}: primvar value index out of bounds"
        elif hasattr(value, "__len__"):
            assert len(value) == expected * element_size, f"{name}: {var.GetName()} value domain mismatch"

    coverage = np.zeros(len(counts), dtype=np.int16)
    subsets = {}
    for subset in material_subsets(mesh):
        subset_path = str(subset.GetPath())
        assert str(subset.GetElementTypeAttr().Get()) == "face", f"{subset_path}: not a face subset"
        faces = np.array(subset.GetIndicesAttr().Get(), dtype=np.int64)
        if len(faces):
            assert faces.min() >= 0 and faces.max() < len(counts), f"{subset_path}: face index out of bounds"
        assert len(set(map(int, faces))) == len(faces), f"{subset_path}: duplicate face assignment"
        coverage[faces] += 1
        bound, _ = UsdShade.MaterialBindingAPI(subset.GetPrim()).ComputeBoundMaterial()
        assert bound, f"{subset_path}: material binding does not resolve"
        subsets[subset.GetPrim().GetName()] = {"faces": len(faces), "material": str(bound.GetPath())}
    if subsets:
        assert (coverage <= 1).all(), f"{name}: overlapping material subset faces"

    bound, _ = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
    assert bound or subsets, f"{name}: no resolved material binding"
    return {
        "points": len(points), "faces": len(counts),
        "triangles": int(np.maximum(0, counts - 2).sum()),
        "extent": extent.tolist(), "subsets": subsets,
        "subsetFullyCovered": bool((coverage == 1).all()) if subsets else None,
    }


def assert_lossless_geometry(original, processed, source_hash):
    """Independently verify exact arrays and the one pinned source correction."""
    assert source_hash == "aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba", "Lossless correction audit requires pinned source."
    before, after = UsdGeom.Mesh(original), UsdGeom.Mesh(processed)
    for getter in ("GetFaceVertexCountsAttr", "GetFaceVertexIndicesAttr"):
        assert np.array_equal(np.asarray(getattr(before, getter)().Get()), np.asarray(getattr(after, getter)().Get())), f"{original.GetPath()}: topology changed"
    def normals(mesh):
        var = UsdGeom.PrimvarsAPI(mesh).GetPrimvar("normals")
        return (var.GetInterpolation(), np.asarray(var.ComputeFlattened())) if var else (mesh.GetNormalsInterpolation(), np.asarray(mesh.GetNormalsAttr().Get()))
    before_interpolation, before_normals = normals(before)
    after_interpolation, after_normals = normals(after)
    assert before_interpolation == after_interpolation, f"{original.GetPath()}: normal interpolation changed"
    assert np.array_equal(before_normals, after_normals), f"{original.GetPath()}: expanded normal values changed"
    expected_points = np.asarray(before.GetPointsAttr().Get(), dtype=np.float32).copy()
    actual_points = np.asarray(after.GetPointsAttr().Get(), dtype=np.float32)
    if not np.array_equal(expected_points, actual_points) and original.GetName() in {"rack01_psu_06_mesh", "rack01_psu_06_mesh_001"}:
        world = UsdGeom.Xformable(original).ComputeLocalToWorldTransform(Usd.TimeCode.Default())
        expected_points += np.asarray(world.GetInverse().TransformDir(Gf.Vec3d(0, 0.4, -1.908)), dtype=np.float32)
    assert np.array_equal(expected_points, actual_points), f"{original.GetPath()}: points changed beyond verified PSU correction"
    for var in UsdGeom.PrimvarsAPI(original).GetPrimvars():
        if var.GetBaseName() == "normals":
            continue
        other = UsdGeom.PrimvarsAPI(processed).GetPrimvar(var.GetBaseName())
        assert other and attr_snapshot(var.GetAttr()) == attr_snapshot(other.GetAttr()), f"{original.GetPath()}: primvar changed {var.GetName()}"
        assert np.array_equal(np.asarray(var.GetIndices()), np.asarray(other.GetIndices())), f"{original.GetPath()}: primvar indices changed {var.GetName()}"


def validate(source_path, output_path, require_lossless=False):
    source_hash, output_hash = sha256(source_path), sha256(output_path)
    source, output = [Usd.Stage.Open(str(path)) for path in (source_path, output_path)]
    assert source and output, "A USD stage failed to load"
    assert_same(str(source.GetDefaultPrim().GetPath()), str(output.GetDefaultPrim().GetPath()), "default prim")
    for key in ("upAxis", "metersPerUnit", "startTimeCode", "endTimeCode", "timeCodesPerSecond"):
        assert_same(source.GetMetadata(key), output.GetMetadata(key), f"stage {key}")
    source_prims, output_prims = authored_prims(source), authored_prims(output)
    assert_same(set(source_prims), set(output_prims), "authored prim paths")
    assert_same(len(source.GetPrototypes()), len(output.GetPrototypes()), "composed prototype count")
    assert len(output.GetPrototypes()) == 1, "Expected a single shared server prototype"
    server_ids = {}
    output_instances = []
    meshes = {}
    for path, original in source_prims.items():
        processed = output_prims[path]
        assert_same(original.GetTypeName(), processed.GetTypeName(), f"{path} schema")
        for key in ("specifier", "active", "instanceable", "references", "customData", "kind"):
            assert_same(str(original.GetMetadata(key)), str(processed.GetMetadata(key)), f"{path} metadata {key}")
        for attr in original.GetAuthoredAttributes():
            name = attr.GetName()
            if not geometry_property(original, name):
                assert_same(attr_snapshot(attr), attr_snapshot(processed.GetAttribute(name)), f"{path}.{name}")
        assert_same(
            {rel.GetName(): [str(p) for p in rel.GetTargets()] for rel in original.GetAuthoredRelationships()},
            {rel.GetName(): [str(p) for p in rel.GetTargets()] for rel in processed.GetAuthoredRelationships()},
            f"{path} relationships",
        )
        if original.IsInstance():
            assert processed.IsInstance(), f"{path}: no longer an instance"
            refs = processed.GetMetadata("references").GetAddedOrExplicitItems()
            assert len(refs) == 1 and not refs[0].assetPath, f"{path}: reference no longer internal"
            assert str(refs[0].primPath) == "/root/prototypes/server_exterior_surface_0", f"{path}: reference changed"
            output_instances.append(path)
        part_id = processed.GetAttribute("userProperties:part_id").Get()
        server_id = processed.GetAttribute("userProperties:server_id").Get()
        if part_id and part_id == server_id:
            server_ids[str(part_id)] = path
        if original.IsA(UsdGeom.Mesh):
            if require_lossless:
                assert_lossless_geometry(original, processed, source_hash)
            before, after = mesh_stats(original), mesh_stats(processed)
            assert_same(set(before["subsets"]), set(after["subsets"]), f"{path} material subset names")
            for name, values in before["subsets"].items():
                assert_same(values["material"], after["subsets"][name]["material"], f"{path}/{name} material")
                if values["faces"]:
                    assert after["subsets"][name]["faces"] > 0, f"{path}/{name}: material region vanished"
            if before["subsetFullyCovered"]:
                assert after["subsetFullyCovered"], f"{path}: material subset coverage became incomplete"
            assert after["triangles"] <= before["triangles"], f"{path}: triangle count increased"
            meshes[path] = {"before": before, "after": after}

    assert_same(set(server_ids), {f"rack01.server{index:02d}" for index in range(1, 19)}, "server identity set")
    assert len(output_instances) == 18, f"Expected 18 instances, found {len(output_instances)}"
    materials = [path for path, prim in output_prims.items() if prim.IsA(UsdShade.Material)]
    archive_entries = []
    with zipfile.ZipFile(output_path) as archive:
        for entry in archive.infolist():
            assert entry.compress_type == zipfile.ZIP_STORED, f"USDZ entry is compressed: {entry.filename}"
            assert not entry.flag_bits & 1, f"USDZ entry is encrypted: {entry.filename}"
            with output_path.open("rb") as stream:
                stream.seek(entry.header_offset + 26)
                name_len = int.from_bytes(stream.read(2), "little")
                extra_len = int.from_bytes(stream.read(2), "little")
            data_offset = entry.header_offset + 30 + name_len + extra_len
            assert data_offset % 64 == 0, f"USDZ entry lacks 64-byte alignment: {entry.filename}"
            archive_entries.append(entry.filename)
    totals = {key: sum(row[key]["triangles"] for row in meshes.values()) for key in ("before", "after")}
    assert_same(source_hash, sha256(source_path), "source changed during validation")
    assert_same(output_hash, sha256(output_path), "output changed during validation")
    return {
        "status": "passed", "source": str(source_path), "output": str(output_path),
        "sourceSHA256": source_hash, "outputSHA256": output_hash,
        "authoredPrims": len(output_prims), "serverRoots": len(server_ids),
        "internalInstances": len(output_instances), "composedPrototypes": len(output.GetPrototypes()),
        "materials": len(materials), "meshes": len(meshes), "storedTriangles": totals,
        "sourceBytes": source_path.stat().st_size, "outputBytes": output_path.stat().st_size,
        "losslessGeometryVerified": require_lossless,
        "archiveEntries": archive_entries, "meshDetails": meshes,
        "limitation": "Validates USD structure and face-material domains; visual fidelity and device performance require separate evidence.",
    }


if __name__ == "__main__":
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    require_lossless = "--lossless" in args
    args = [arg for arg in args if arg != "--lossless"]
    root = Path(__file__).resolve().parents[1]
    source_path = Path(args[0]) if args else root / "runtime/asset-source/datacenter-rack/models/lazy/rack-exterior.usdz"
    output_path = Path(args[1]) if len(args) > 1 else root / "runtime/processed-assets/rack-exterior-mobile.usdz"
    try:
        report = validate(source_path, output_path, require_lossless=require_lossless)
        report_path = output_path.with_suffix(".validation.json")
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: value for key, value in report.items() if key != "meshDetails"}, indent=2))
    except Exception as error:
        print(f"VALIDATION_FAILED: {type(error).__name__}: {error}", flush=True)
        raise
