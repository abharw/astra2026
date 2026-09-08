"""Small, format-only OpenUSD processing helpers for offline asset compilation."""

from pathlib import Path


def compact_normals(source_path: Path, output_path: Path) -> dict:
    """Index repeated normals; verify exact geometry and expanded normal equality.

    No quantization, vertex welding, decimation or coordinate conversion occurs.
    Call with Blender's bundled OpenUSD/NumPy, or an equivalent Python runtime.
    Native importer compatibility remains a separate acceptance requirement.
    """
    import numpy as np
    from pxr import Sdf, Usd, UsdGeom, UsdUtils, Vt

    if source_path.resolve() == output_path.resolve():
        raise ValueError("Keep the original pack separate from the storage derivative.")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    source = Usd.Stage.Open(str(source_path))
    layer_path = output_path.with_suffix(".usdc")
    source.GetRootLayer().Export(str(layer_path))
    stage = Usd.Stage.Open(str(layer_path))
    changed = []
    mesh_paths = []
    for prim in stage.TraverseAll():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh_paths.append(str(prim.GetPath()))
        mesh = UsdGeom.Mesh(prim)
        authored = mesh.GetNormalsAttr().Get()
        if authored is None:
            continue
        normals = np.asarray(authored, dtype=np.float32)
        if not len(normals):
            continue
        unique, indices = np.unique(normals, axis=0, return_inverse=True)
        if unique.nbytes + len(indices) * 4 >= normals.nbytes:
            continue
        variable = UsdGeom.PrimvarsAPI(prim).CreatePrimvar(
            "normals", Sdf.ValueTypeNames.Normal3fArray, mesh.GetNormalsInterpolation()
        )
        variable.Set(Vt.Vec3fArray.FromNumpy(unique))
        variable.SetIndices(Vt.IntArray.FromNumpy(indices.astype(np.int32)))
        prim.RemoveProperty("normals")
        changed.append(str(prim.GetPath()))
    compact_layer = output_path.with_name(output_path.stem + "-packed.usdc")
    stage.GetRootLayer().Export(str(compact_layer))
    if output_path.exists():
        output_path.unlink()
    if not UsdUtils.CreateNewUsdzPackage(
        Sdf.AssetPath(str(compact_layer)), str(output_path)
    ):
        raise RuntimeError("USDZ packaging failed.")
    reopened = Usd.Stage.Open(str(output_path))
    if {str(p.GetPath()) for p in source.TraverseAll()} - {
        str(p.GetPath()) for p in reopened.TraverseAll()
    }:
        raise AssertionError("A source primitive disappeared during compaction.")
    for path in mesh_paths:
        original = UsdGeom.Mesh(source.GetPrimAtPath(path))
        processed = UsdGeom.Mesh(reopened.GetPrimAtPath(path))
        for getter in (
            "GetPointsAttr",
            "GetFaceVertexCountsAttr",
            "GetFaceVertexIndicesAttr",
        ):
            before = getattr(original, getter)().Get()
            after = getattr(processed, getter)().Get()
            if not np.array_equal(np.asarray(before), np.asarray(after)):
                raise AssertionError(f"Geometry changed at {path}.")
        before = original.GetNormalsAttr().Get()
        if before is not None:
            variable = UsdGeom.PrimvarsAPI(processed).GetPrimvar("normals")
            after = (
                variable.ComputeFlattened()
                if variable
                else processed.GetNormalsAttr().Get()
            )
            if not np.array_equal(np.asarray(before), np.asarray(after)):
                raise AssertionError(f"Expanded normal values changed at {path}.")
            interpolation = (
                variable.GetInterpolation()
                if variable
                else processed.GetNormalsInterpolation()
            )
            if interpolation != original.GetNormalsInterpolation():
                raise AssertionError(f"Normal interpolation changed at {path}.")
    return {
        "inputBytes": source_path.stat().st_size,
        "outputBytes": output_path.stat().st_size,
        "indexedMeshCount": len(changed),
        "checkedMeshCount": len(mesh_paths),
        "topologyAndPositionsIdentical": True,
        "expandedNormalsIdentical": True,
        "nativeImporterVerified": False,
    }
