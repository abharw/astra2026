"""Isolated Blender smoke test, no render or shared-scene edits."""
from pathlib import Path
import datetime, importlib.util, json, time
import bpy

HERE=Path(__file__).resolve().parent
PROJECT=HERE.parents[1]
module_path=PROJECT/'source/pcb_population.py'
spec=importlib.util.spec_from_file_location('pcb_population',module_path)
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
for obj in list(bpy.data.objects):bpy.data.objects.remove(obj,do_unlink=True)
result=module.build_pcb_population()
receipt=result['metadata']['receipt'];objects=result['objects'];parts=result['metadata']['parts']
assert len(objects)==6663,receipt
assert len(parts)==len(objects)
assert receipt['inherited_height_refdes']==['J110']
assert receipt['source_pin_alignment_max_error_mm']<0.001
assert all(o['population_status']=='PWA-BOM-listed' for o in objects)
assert all(o['body_created'] for o in objects)
assert all(len(o.data.vertices)>0 for o in objects)
assert all(o['part_id'] in parts for o in objects)
bpy.context.view_layer.update()
max_center_error=0;side_counts={'top':0,'bottom':0};bad_z=[]
for obj in objects:
    p=parts[obj['part_id']];side_counts[p['side']]+=1
    max_center_error=max(max_center_error,abs(obj.matrix_local.translation.x-p['x_mm']*.001),abs(obj.matrix_local.translation.y-p['y_mm']*.001))
    world_z=[(obj.matrix_local @ v.co).z for v in obj.data.vertices]
    if p['side']=='top' and min(world_z)<-1e-8:bad_z.append(obj.name)
    if p['side']=='bottom' and max(world_z)>-.003+1e-8:bad_z.append(obj.name)
assert max_center_error<1e-7,max_center_error
assert not bad_z,bad_z[:10]
receipt.update(blender_version=bpy.app.version_string,blender_build_hash=bpy.app.build_hash.decode(),
               checked_center_max_error_m=max_center_error,side_counts=side_counts,
               source_outline_geometry='All populated source package meshes have vertices; no empty substitutes',
               meshes_in_file=len(bpy.data.meshes),mesh_vertices=sum(len(m.vertices) for m in bpy.data.meshes),
               mesh_polygons=sum(len(m.polygons) for m in bpy.data.meshes),
               surface_checks_passed=True)
# Persist the exact metadata and a compact inspectable scene; no render.
(HERE/'smoke-metadata.json').write_text(json.dumps(result['metadata'],separators=(',',':')))
bpy.ops.wm.save_as_mainfile(filepath=str(HERE/'pcb-population-smoke.blend'),compress=True)
# Check duplicate exclusion on a bounded source subset, not a second full build.
data=json.loads(module.DEFAULT_SOURCE.read_text())
requested={'U1','U10','U14','J110'}
data['components']=[c for c in data['components'] if c['refdes'] in requested]
subset=HERE/'smoke-subset.json';subset.write_text(json.dumps(data,separators=(',',':')))
second=module.build_pcb_population(skip_refdes={'pcb.U1','U10'},source_path=subset)
assert {o['refdes'] for o in second['objects']}=={'U14','J110'}
receipt['skip_refdes_check']='U1 and pcb.U10 conventions excluded; U14 and J110 retained'
(HERE/'smoke-receipt.json').write_text(json.dumps(receipt,indent=2))
with (PROJECT/'logs/pcb-population-actions.jsonl').open('a') as f:
    f.write(json.dumps(dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           actor='rack_openhardware_research',detail='Isolated Blender full-population smoke test; no render',receipt=receipt))+'\n')
print('PCB_SMOKE_RECEIPT '+json.dumps(receipt))
