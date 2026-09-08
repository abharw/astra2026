"""Compile the pinned USDZ assets into bounded, individually lazy-loaded Unity meshes.

Run with Blender's Python. No source geometry is procedurally substituted.
Mesh vertices/normals preserve source data; indexed material groups preserve PBR.
All geometry is in the existing AssemblyVisual normalized coordinate system.
"""
import array
import gzip
import hashlib
import json
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
import bpy
from mathutils import Matrix, Vector

BASE = Path(__file__).resolve().parents[1]
SOURCE = BASE / "SourceAssets/AravRack"
DEST = BASE / "Assets/StreamingAssets/Rack"
DEST.mkdir(parents=True, exist_ok=True)
HEIGHT = 2.21
# Blender Z up; authored front is -Y. Unity model front is +Z.
# Reflect X as well to preserve the source's front-view left/right in Unity's
# left-handed space. This transform has det -1; reverse triangle winding below.
C = Matrix(((-1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))
CI = C.inverted()


def write_json(name, value):
    (DEST / name).write_text(json.dumps(value, separators=(",", ":")) + "\n")


def ancestors(instance):
    obj = instance.parent if instance.is_instance else instance.object
    result = []
    while obj:
        result.append(obj.name)
        obj = obj.parent
    return result


def material_value(material):
    result = {"name": material.name if material else "Source material", "color": [0.6, 0.6, 0.6, 1], "metallic": 0, "roughness": 0.5}
    if not material:
        return result
    result["color"] = list(material.diffuse_color)
    result["metallic"] = material.metallic
    result["roughness"] = material.roughness
    if material.use_nodes:
        bsdf = next((n for n in material.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf:
            result.update(color=list(bsdf.inputs["Base Color"].default_value), metallic=bsdf.inputs["Metallic"].default_value, roughness=bsdf.inputs["Roughness"].default_value)
            if bsdf.inputs["Base Color"].is_linked:
                raise ValueError("Textured material needs an explicit texture export: " + material.name)
    return result


def mesh_data(obj):
    assert not obj.modifiers, "Source has modifiers; evaluate and snapshot it explicitly"
    mesh = obj.data
    mesh.calc_loop_triangles()
    vertices, normals, lookup = [], [], {}
    groups = [[] for _ in range(max(1, len(mesh.materials)))]
    # Preserve split corner normals. A position-only weld destroys hard surface edges.
    for tri in mesh.loop_triangles:
        indices = []
        for loop_index in tri.loops:
            vi = mesh.loops[loop_index].vertex_index
            normal = mesh.corner_normals[loop_index].vector
            key = (vi, tuple(round(v, 7) for v in normal))
            if key not in lookup:
                lookup[key] = len(vertices)
                vertices.append(list((C.to_3x3() @ mesh.vertices[vi].co) / HEIGHT))
                normals.append(list(C.to_3x3() @ normal))
            indices.append(lookup[key])
        # Compensate for the reflection, retaining outward source normals.
        groups[tri.material_index].extend((indices[0], indices[2], indices[1]))
    materials = [material_value(m) for m in mesh.materials] or [material_value(None)]
    return vertices, normals, groups, materials


def package(name, entries, origin):
    unique, metadata, instances = {}, [], []
    bounds = {}
    for instance, part_id in entries:
        obj = instance.object
        key = obj.data.name
        if key not in unique:
            unique[key] = len(unique)
            verts, norms, groups, materials = mesh_data(obj)
            metadata.append({"name": key, "vertices": verts, "normals": norms, "groups": groups, "materials": materials})
        mesh_id = unique[key]
        matrix = C @ instance.matrix_world @ CI
        matrix.translation = (matrix.translation - origin) / HEIGHT
        location, rotation, scale = matrix.decompose()
        instances.append({"part": part_id, "mesh": mesh_id, "position": list(location), "rotation": [rotation.x, rotation.y, rotation.z, rotation.w], "scale": list(scale)})
        for v in metadata[mesh_id]["vertices"]:
            point = matrix @ Vector(v)
            # matrix's linear part is unscaled source instance scale; verts are normalized.
            if part_id not in bounds:
                bounds[part_id] = [list(point), list(point)]
            for axis in range(3):
                bounds[part_id][0][axis] = min(bounds[part_id][0][axis], point[axis])
                bounds[part_id][1][axis] = max(bounds[part_id][1][axis], point[axis])
    raw = bytearray(b"RACKM001")
    raw.extend(struct.pack("<I", len(metadata)))
    mesh_summary = []
    for item in metadata:
        raw.extend(struct.pack("<I", len(item["vertices"])))
        for field in ("vertices", "normals"):
            values = array.array("f", (v for row in item[field] for v in row))
            if sys.byteorder != "little": values.byteswap()
            raw.extend(values.tobytes())
        raw.extend(struct.pack("<I", len(item["groups"])))
        for indices in item["groups"]:
            raw.extend(struct.pack("<I", len(indices)))
            values = array.array("I", indices)
            if sys.byteorder != "little": values.byteswap()
            raw.extend(values.tobytes())
        mesh_summary.append({"name": item["name"], "vertices": len(item["vertices"]), "triangles": sum(len(g) for g in item["groups"]) // 3, "materials": item["materials"]})
    blob = gzip.compress(bytes(raw), compresslevel=6, mtime=0)
    # Unity Android expands files ending in .gz while packaging StreamingAssets.
    filename = name + ".rackbin"
    (DEST / filename).write_bytes(blob)
    result = {"file": filename, "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob), "decodedBytes": len(raw), "meshes": mesh_summary, "instances": instances, "bounds": bounds}
    print("RACK_PACKAGE " + json.dumps({"name": name, "meshes": len(metadata), "bytes": len(blob), "triangles": sum(m["triangles"] for m in mesh_summary)}), flush=True)
    return result


def imported(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.wm.usd_import(filepath=str(path))
    # Keep the dependency graph alive while consuming its instances.
    graph = bpy.context.evaluated_depsgraph_get()
    return graph, [SimpleNamespace(object=i.object.original, parent=i.parent.original if i.parent else None, is_instance=i.is_instance, matrix_world=i.matrix_world.copy()) for i in graph.object_instances if i.object.type == "MESH" and i.show_self]


catalog = json.loads((SOURCE / "app-catalog.json").read_text())
detail = json.loads((SOURCE / "detail-catalog.json").read_text())
recipe = json.loads((SOURCE / "teaching-groups.json").read_text())
for label, data in (("rack-exterior", catalog), ("server-teaching", detail)):
    path = SOURCE / "Assets" / (label + ".usdz")
    assert hashlib.sha256(path.read_bytes()).hexdigest() == data["sha256"], "Source hash mismatch"
graph, entries = imported(SOURCE / "Assets/rack-exterior.usdz")
lo, hi = Vector((1e9,) * 3), Vector((-1e9,) * 3)
classified, servers = [], {}
for instance in entries:
    chain = ancestors(instance)
    match = next((p for p in catalog["parts"] if p["entityName"] and p["entityName"] in chain), None)
    part_id = match["partID"] if match else "rack01.frame"
    classified.append((instance, part_id))
    if match:
        # Source exterior is a single mesh under each server wrapper at this pin.
        matrix = C @ instance.matrix_world @ CI
        servers[part_id] = matrix
    for corner in instance.object.bound_box:
        point = C @ instance.matrix_world @ Vector(corner)
        for axis in range(3): lo[axis] = min(lo[axis], point[axis]); hi[axis] = max(hi[axis], point[axis])
assert len(servers) == 18, f"Expected all 18 source server instances; got {len(servers)}"
assert abs((hi - lo).y - HEIGHT) < 0.005, list(hi-lo)
center = (lo + hi) / 2
packages = {"exterior": package("exterior", classified, center)}
server_positions = {key: list((matrix.translation - center) / HEIGHT) for key, matrix in servers.items()}
# Preserve non-translation source transforms too, and fail if this asset assumption changes.
assert all(abs(m[r][c] - (1 if r == c else 0)) < 1e-5 for m in servers.values() for r in range(3) for c in range(3))
graph, entries = imported(SOURCE / "Assets/server-teaching.usdz")
groups = []
for source_part in detail["parts"]:
    group = source_part["partID"].split(".")[-1]
    matches = [i for i in entries if i.object.name == source_part["entityName"] + "_mesh" or source_part["entityName"] in ancestors(i)]
    assert len(matches) == 1, (group, len(matches))
    packages[group] = package(group, [(matches[0], group)], Vector((0, 0, 0)))
    authored = next(g for g in recipe["groups"] if g["id"] == group)
    groups.append({"id": group, "name": source_part["name"], "description": source_part["description"], "representation": authored["representation"]})
manifest = {"version": 1, "assetId": "arav-rack-v1", "height": HEIGHT, "sizeMeters": list(hi-lo), "sourceCenter": list(center), "sourceCommit": "ef10dcbd5160b05205d61f5080a31ef117cfa900", "sourceHashes": {"exterior": catalog["sha256"], "teaching": detail["sha256"]}, "parts": catalog["parts"], "groups": groups, "serverPositions": server_positions, "packages": packages, "limits": recipe["limits"]}
write_json("catalog.json", manifest)
print("RACK_EXPORT_COMPLETE " + str(DEST), flush=True)
