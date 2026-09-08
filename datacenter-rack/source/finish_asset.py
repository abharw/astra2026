"""Apply verified surface repairs and teaching/inspection views to the first build."""
import sys,json,math
from pathlib import Path
import bpy
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'source'))
from build_asset import apply_cad_repairs,new_scene,collection,studio
from processor_study import build_processor_study,set_exploded

bpy.ops.wm.open_mainfile(filepath=str(ROOT/'models/datacenter-rack-v001.blend'))
idx=json.loads((ROOT/'models/barreleye-evt-mesh/assembly.json').read_text())
objs={o['part_id'].removeprefix('server.cad.'):o for o in bpy.data.objects if str(o.get('part_id','')).startswith('server.cad.')}
repairs=apply_cad_repairs(objs,idx)
thermal=json.loads((ROOT/'research/cad-diagnostics/cpu-material-map.json').read_text())['rows']
copper={r['definition_label'] for r in thermal if 'copper' in r['suggested_material'].lower()}
for o in objs.values():
    if o.type=='MESH' and o.get('cad_definition_id') in copper:
        o.material_slots[0].link='OBJECT';o.material_slots[0].material=bpy.data.materials['C1100 copper thermal assembly']
study=new_scene('04 · Processor study');bpy.context.window.scene=study
studycol=collection('POWER9 · explanatory internal architecture',study)
cpu,meta=build_processor_study(studycol);set_exploded(cpu,1)
studio(study,(.155,-.21,.15),(0,0,.027),.145,(1800,1800),floor=-.017)
study['evidence_level']='Explanatory internal study; not exact transistor or package internal CAD'
(ROOT/'models/processor-study-receipt.json').write_text(json.dumps(meta,indent=2))
master=bpy.data.collections['SERVER · fully editable source assembly']
# Put the editable source-bound visual power harness in the reusable server.
old=bpy.data.objects.get('cable.ou01.48V_input_to_J27')
if old:
    old.parent=None;old.location=(0,.4,-.18)
    for c in list(old.users_collection):c.objects.unlink(old)
    master.objects.link(old);old.name='server.cable.48V_input_to_J27';old['part_id']=old.name
    old['endpoint_from']='server.cad.node-09930';old['endpoint_to']='pcb.J27'
    old['route_review']='Source-bound visual route; contact mating and collision not certified'
for s in bpy.data.scenes:
    for c in s.collection.children:
        if '/ studio' in c.name:
            for o in c.objects:
                o.hide_select=True
                if 'part_id' in o:del o['part_id']
    s.cycles.samples=64;s.cycles.use_denoising=True
    s['model_status']='Source-derived visual training asset; see embedded README and external validation receipt'
for p in [ROOT/'source/rack_inspector.py',ROOT/'docs/PROCESSOR_STUDY.md',ROOT/'docs/HACKATHON_PROCESS.md']:
    text=bpy.data.texts.get(p.name) or bpy.data.texts.new(p.name);text.clear();text.write(p.read_text())
readme=bpy.data.texts.get('READ ME · asset status');readme.clear();readme.write('RACK LAB — OPEN RACK V2 / BARRELEYE G2 EVT\n\n01 Full rack:18 linked server instances, power shelf and editable management cables.\n02 Open server:complete editable master; source CAD, fabricated PCB parts, class-analogue RDIMMs.\n03 Motherboard fabrication:actual registered Gerber surfaces and named components.\n04 Processor study:explanatory internal architecture; explicitly schematic.\n\nRun rack_inspector.py for the N-sidebar Rack Lab. Search refdes/MPN/name, frame, isolate, explode/restore, edit curves.\nSI metres. Presentation floors/lights are separate studio collections.\nSources, licenses and defects are documented alongside this file. No physics/electrical/AR performance certification.\n')
scene=bpy.data.scenes['01 · Full rack'];bpy.context.window.scene=scene
for o in scene.objects:o.select_set(False)
bpy.context.view_layer.objects.active=None
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type=='VIEW_3D':
            sp=area.spaces.active;sp.clip_start=.0001;sp.clip_end=100
            sp.shading.type='SOLID';sp.shading.color_type='MATERIAL';sp.shading.light='STUDIO'
            sp.overlay.show_relationship_lines=False;sp.overlay.show_extras=False;sp.overlay.show_floor=False
            sp.region_3d.view_perspective='CAMERA';sp.region_3d.view_camera_zoom=0
dest=ROOT/'models/datacenter-rack-v002.blend'
bpy.ops.wm.save_as_mainfile(filepath=str(dest),compress=True)
receipt={'schema':'rack-asset-finish/v1','file':dest.name,'objects':len(bpy.data.objects),'unique_meshes':len(bpy.data.meshes),'curves':len([o for o in bpy.data.objects if o.type=='CURVE']),'scenes':[s.name for s in bpy.data.scenes],'repaired_definitions':repairs,'processor_study_objects':len(studycol.objects),'selected_geometry_defects':json.loads((ROOT/'research/cad-diagnostics/selected-configuration-defects.json').read_text()),'render_status':'pending visual review'}
(ROOT/'models/asset-finish-receipt.json').write_text(json.dumps(receipt,indent=2))
print('FINISHED_ASSET',json.dumps({k:v for k,v in receipt.items() if k!='selected_geometry_defects'}),flush=True)
