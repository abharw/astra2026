"""Reproduce the pinned rack source PSU 6 transform defect in Blender.

Run with Blender --background --factory-startup --python <this file>.
Requires the source checkout documented in docs/imported-rack-review.md.
Writes its report only beneath ignored runtime/asset-source.
"""
from pathlib import Path
import bpy,json,sys,time
from mathutils import Vector
root=Path(__file__).resolve().parents[1]/'runtime/asset-source'
src=(root/'datacenter-rack/source/rack_frame.py').read_text()
records={}
for mode in ['original','update_after_child_restore']:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    code=src
    if mode!='original':
        old='for child,matrix in matrices.items():child.matrix_world=matrix'
        assert code.count(old)==1
        code=code.replace(old,old+'\n        bpy.context.view_layer.update()')
    env={'__name__':'rack_frame_intake_review'}
    exec(compile(code,'rack_frame.py','exec'),env)
    env['build_rack']();bpy.context.view_layer.update()
    dg=bpy.context.evaluated_depsgraph_get()
    rows={}
    for n in range(1,7):
        key=f'rack.psu.{n:02d}'
        objects=[o for o in bpy.data.objects if o.name.startswith(key+'.') and o.type in {'MESH','CURVE','FONT'}]
        points=[o.evaluated_get(dg).matrix_world@Vector(v) for o in objects for v in o.evaluated_get(dg).bound_box]
        rows[key]={'min':[min(v[i] for v in points) for i in range(3)],'max':[max(v[i] for v in points) for i in range(3)],'object_count':len(objects),'object_world_origins':{o.name:list(o.matrix_world.translation) for o in objects}}
    records[mode]=rows
checks={}
for k,original in records['original'].items():
    corrected=records['update_after_child_restore'][k]
    deltas={name:[b-a for a,b in zip(pos,corrected['object_world_origins'][name])] for name,pos in original['object_world_origins'].items()}
    expected=[0,.4,-1.908] if k=='rack.psu.06' else [0,0,0]
    checks[k]={'object_count':len(deltas),'expected_correction':expected,'max_delta_error':max(abs(a-b) for d in deltas.values() for a,b in zip(d,expected)),'original_bounds':{x:original[x] for x in ['min','max']},'corrected_bounds':{x:corrected[x] for x in ['min','max']}}
report={'blender_version':bpy.app.version_string,'method':'Execute committed rack_frame.py twice in isolated factory-empty scene. Second run adds one view_layer.update() after each loop restores child world matrices. No source files or original binary mutated.','checks':checks}
(root/'psu-offset-reproduction.json').write_text(json.dumps(report,indent=2)+'\n')
assert all(x['max_delta_error']<1e-5 for x in checks.values()),checks
print('PSU_OFFSET_REPRODUCED',json.dumps(report),flush=True)
