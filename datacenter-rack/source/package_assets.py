"""Package pregenerated detail separately from a light, exterior-only rack scene.

No detail library is loaded by the default scene. Low-detail exterior geometry
is a declared CAD simplification; the high-detail source remains unchanged.
"""
from pathlib import Path
import json,sys,math,time,hashlib
import bpy,bmesh
import numpy as np
from mathutils import Matrix,Vector
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'source'))
from build_asset import studio,collection,tag
OUT=ROOT/'models/lazy';OUT.mkdir(exist_ok=True)

def bounds(objects):
    pts=[o.matrix_world@Vector(p) for o in objects if o.type in {'MESH','CURVE','FONT'} for p in o.bound_box]
    return [[min(p[i] for p in pts) for i in range(3)],[max(p[i] for p in pts) for i in range(3)]] if pts else [[0]*3,[0]*3]

def source_id(o):return str(o.get('part_id','')).removeprefix('server.cad.')

def libcollection(name,objects):
    c=bpy.data.collections.new(name)
    for o in objects:c.objects.link(o)
    return c

def merge_geometry(name,objects,dest,*,simplify=False):
    """Bake evaluated transforms/materials into a compact exterior mesh."""
    vertices=[];faces=[];mi=[];materials=[];mat_map={};source_ids=[];cache={};raw_tri=0
    for number,obj in enumerate(objects):
        if obj.type not in {'MESH','CURVE','FONT'}:continue
        source_world=obj.matrix_world.copy()
        if obj.type=='MESH' and not obj.modifiers:mesh=obj.data.copy()
        else:
            temporary=obj.copy();temporary.parent=None;temporary.matrix_world=Matrix.Identity(4);dest.objects.link(temporary)
            deps=bpy.context.evaluated_depsgraph_get();mesh=bpy.data.meshes.new_from_object(temporary.evaluated_get(deps),depsgraph=deps)
            bpy.data.objects.remove(temporary,do_unlink=True)
        if not mesh.polygons:bpy.data.meshes.remove(mesh);continue
        mesh.calc_loop_triangles();raw_tri+=len(mesh.loop_triangles)
        if simplify and obj.type=='MESH':
            # Welding CAD face boundaries enables useful planar simplification.
            bm=bmesh.new();bm.from_mesh(mesh)
            bmesh.ops.remove_doubles(bm,verts=bm.verts,dist=.000002)
            bmesh.ops.dissolve_limit(bm,angle_limit=.04,use_dissolve_boundaries=False,verts=bm.verts,edges=bm.edges)
            bm.to_mesh(mesh);bm.free();mesh.update();mesh.calc_loop_triangles()
            budget=5000 if source_id(obj)=='node-00007' else 1800 if max(obj.dimensions)>.3 else 500
            if len(mesh.loop_triangles)>budget:
                temp=bpy.data.objects.new('temporary exterior simplification',mesh);dest.objects.link(temp)
                dec=temp.modifiers.new('Exterior distance LOD','DECIMATE');dec.ratio=max(.003,budget/len(mesh.loop_triangles));dec.use_collapse_triangulate=True
                dg=bpy.context.evaluated_depsgraph_get();low=bpy.data.meshes.new_from_object(temp.evaluated_get(dg),depsgraph=dg)
                bpy.data.objects.remove(temp,do_unlink=True);bpy.data.meshes.remove(mesh);mesh=low
        offset=len(vertices);world=source_world
        vertices.extend([tuple(world@v.co) for v in mesh.vertices])
        # Object-linked materials are resolved before merging.
        slots=[s.material for s in obj.material_slots]
        local_mats=[]
        for slot in slots:
            if slot is None:local_mats.append(0);continue
            if slot.name not in mat_map:mat_map[slot.name]=len(materials);materials.append(slot)
            local_mats.append(mat_map[slot.name])
        for face in mesh.polygons:
            faces.append(tuple(offset+v for v in face.vertices));mi.append(local_mats[min(face.material_index,len(local_mats)-1)] if local_mats else 0)
        source_ids.append(obj.get('part_id',obj.name));bpy.data.meshes.remove(mesh)
        if number and number%25==0:print('MERGE_PROGRESS',name,number,len(objects),flush=True)
    m=bpy.data.meshes.new(name+'.mesh');m.from_pydata(vertices,[],faces);m.update()
    for material in materials:m.materials.append(material)
    if mi:m.polygons.foreach_set('material_index',np.asarray(mi,dtype=np.int32))
    m.polygons.foreach_set('use_smooth',np.ones(len(m.polygons),dtype=bool))
    if hasattr(m,'set_sharp_from_angle'):m.set_sharp_from_angle(angle=.65)
    obj=bpy.data.objects.new(name,m);dest.objects.link(obj)
    tag(obj,name,'Exterior distance representation derived from saved source geometry','CAD-derived LOD simplification' if simplify else 'Authored exterior aggregation')
    obj['source_parts_json']=json.dumps(source_ids);obj['detail_load_policy']='Load saved detailed library on inspect intent'
    m.calc_loop_triangles();return obj,{'source_objects':len(source_ids),'source_triangles':raw_tri,'exterior_triangles':len(m.loop_triangles),'vertices':len(m.vertices)}

started=time.monotonic();bpy.ops.wm.open_mainfile(filepath=str(ROOT/'models/datacenter-rack-v002.blend'))
source_objects=list(bpy.data.objects);master=bpy.data.collections['SERVER · fully editable source assembly']
board_objects=set(bpy.data.collections['Motherboard study · selected geometry'].objects)
memory_objects={o for o in master.objects if o.name.startswith('server.memory.')}
mechanical_objects=set(master.objects)-board_objects-memory_objects
# Include transform ancestors without importing any sibling geometry.
def with_parents(items):
    out=set(items)
    for obj in list(out):
        p=obj.parent
        while p:out.add(p);p=p.parent
    return out
details={
  'server.mechanical':libcollection('DETAIL · server.mechanical',with_parents(mechanical_objects)),
  'server.motherboard':libcollection('DETAIL · server.motherboard',with_parents(board_objects)),
  'server.memory':libcollection('DETAIL · server.memory',with_parents(memory_objects)),
  'processor.study':libcollection('DETAIL · processor.study',set(bpy.data.collections['POWER9 · explanatory internal architecture'].objects)),
}
assets={}
for aid,col in details.items():
    assets[aid]={'asset_id':aid,'collection':col.name,'library':'parts-library.blend','bounds_m':bounds(col.objects),'objects':len(col.objects),'description':{'server.mechanical':'Open server mechanical assemblies, drives, fans, heatsinks and source-bound cables','server.motherboard':'Registered EVT3 board and source-listed components with refdes and manufacturer identities','server.memory':'32 documented-class analogue RDIMMs at source positions; fitted SKU not asserted','processor.study':'Separate explanatory POWER9 package and functional architecture; not transistor layout'}[aid],'load':'on inspect/question intent only','replaces_exterior':aid=='server.mechanical'}
library=OUT/'parts-library.blend';bpy.data.libraries.write(str(library),set(details.values()),path_remap='RELATIVE_ALL',fake_user=True,compress=True)
print('SAVED_LAZY_LIBRARY',library.stat().st_size,flush=True)

# Build one small shared exterior from actual outermost CAD surfaces.
workscene=bpy.data.scenes.new('Packaging · isolated evaluation');bpy.context.window.scene=workscene
servercol=bpy.data.collections.new('EXTERIOR · server.closed')
bpy.context.scene.collection.children.link(servercol)
lidset=set(bpy.data.collections['SERVER · removable cover'].objects)
selected=[]
for obj in set(master.objects)|lidset:
    if obj.type!='MESH' or not obj.get('cad_name'):continue
    name=obj.get('cad_name','').upper()
    if any(token in name for token in ['SCREW','WASHER','BALL_','CONTACT','NUT_','SPRING']):continue
    bb=bounds([obj]);lo,hi=bb;size=[b-a for a,b in zip(lo,hi)]
    if max(size)<.012:continue
    if obj in board_objects and size[1]>.060:continue
    if any(word in name for word in ['PCBA','PCB_','PCB-']):continue
    outside=lo[1]<.027 or hi[1]>.865 or lo[0]<-.266 or hi[0]>.266 or (hi[2]>.09 and max(size)>.10)
    if outside or obj in lidset:selected.append(obj)
print('EXTERIOR_SELECTION',len(selected),flush=True)
exterior,exterior_receipt=merge_geometry('server.exterior.surface',selected,servercol,simplify=True)
exterior['asset_id']='server.exterior';exterior['manufacturer']='Open Compute / Inventec';exterior['model']='Barreleye G2 EVT';exterior['source_url']='https://github.com/opencomputeproject/zaius-barreleye-g2'
assets['server.exterior']={'asset_id':'server.exterior','collection':servercol.name,'library':'exterior-library.blend','description':'Closed server distance LOD. High-detail geometry is pregenerated separately.','bounds_m':bounds([exterior]),**exterior_receipt}
print('EXTERIOR_READY',exterior_receipt,flush=True)

scene=bpy.data.scenes.new('Rack Lab · exterior only');bpy.context.window.scene=scene
scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=1
rackcol=bpy.data.collections.new('RACK · exterior template');scene.collection.children.link(rackcol)
rackroot=bpy.data.objects.new('rack01 · Open Rack V2',None);rackcol.objects.link(rackroot);tag(rackroot,'rack01','Open Rack V2 training rack exterior');rackroot['rack_id']='rack01';rackroot['asset_id']='rack.exterior';rackroot['slot_pitch_m']=.048;rackroot['slot_base_m']=.18
frame_receipts={}
for group in ['structure','retention','supports','hardware','power','labels']:
    col=bpy.data.collections.get('rack.'+group)
    if not col:continue
    groups={}
    for obj in col.objects:
        if obj.type not in {'MESH','CURVE','FONT'}:continue
        # Preserve PSU-level selection; the rest is grouped by rack role.
        psu=obj.name.split('.')[2] if obj.name.startswith('rack.psu.') else None
        key='psu.'+psu if psu else group
        groups.setdefault(key,[]).append(obj)
    for key,obs in groups.items():
        merged,receipt=merge_geometry('rack01.'+key,obs,rackcol);merged.parent=rackroot;merged['rack_id']='rack01'
        if key.startswith('psu.'):
            merged['manufacturer']='Bel Power Solutions';merged['manufacturer_part_number']='TET4000-48-069RA';merged['description']='Removable documented power-supply exterior; internal electronics not modeled'
        frame_receipts[key]=receipt

# Individual cables remain selectable and their editable curves remain in the file.
wirecol=bpy.data.collections.get('rack.cabling')
if wirecol is None:
    wirecol=next((c for c in bpy.data.collections if any(o.name.startswith('cable.ou') for o in c.objects)),None)
if wirecol:
    accessories=[]
    for o in list(wirecol.objects):
        if o.type=='CURVE' and not o.name.startswith('server.'):
            clone=o.copy();clone.data=o.data.copy();rackcol.objects.link(clone);clone.parent=rackroot;clone.matrix_world=o.matrix_world;clone['rack_id']='rack01';clone['part_id']='rack01.'+o.get('part_id',o.name)
        elif o.type in {'MESH','FONT'}:accessories.append(o)
    if accessories:
        obj,receipt=merge_geometry('rack01.management.patch-panel-and-plugs',accessories,rackcol);obj.parent=rackroot;frame_receipts['management']=receipt

servers=[]
for number,ou in enumerate(range(1,36,2),1):
    sid=f'rack01.server{number:02d}';root=bpy.data.objects.new(sid,None);rackcol.objects.link(root);root.parent=rackroot;root.location=(0,-.4,.18+(ou-1)*.048)
    root.empty_display_size=.025;tag(root,sid,f'Barreleye G2 training server at OU{ou}–{ou+1}');root['server_id']=sid;root['rack_id']='rack01';root['asset_id']='server.exterior';root['slot_ou']=ou
    inst=bpy.data.objects.new(sid+'.exterior',None);rackcol.objects.link(inst);inst.parent=root;inst.instance_type='COLLECTION';inst.instance_collection=servercol;inst['server_id']=sid;inst['rack_id']='rack01';inst['asset_id']='server.exterior';inst['part_id']=sid+'.exterior'
    servers.append({'part_id':sid,'asset_id':'server.exterior','slot_ou':ou,'position_m':list(root.location),'children_on_demand':['server.mechanical','server.motherboard','server.memory','processor.study']})
studio(scene,(3.1,-4.5,2.8),(0,.02,1.12),2.95,(1500,1900),floor=0)
scene.cycles.device='CPU';scene.cycles.samples=32
scene['lazy_library_path']='//parts-library.blend';scene['lazy_manifest_path']='//manifest.json';scene['initial_detail_loaded']=False
scene['instructions']='Default exterior stack only. Questions resolve to saved asset IDs. Rack Lab loads detail libraries only on request.'

assets['rack.exterior']={'asset_id':'rack.exterior','collection':'RACK · exterior template','library':'rack-exterior.blend','initial_load':True}
manifest={'schema':'rack-lazy-assets/v1','units':'meters','coordinates':{'x':'right','y':'front to rear','z':'up'},'default_scene':'rack-exterior.blend','initial_load':['rack.exterior','server.exterior'],'detail_policy':'pregenerated assets; never regenerate at question time','library':'parts-library.blend','assets':assets,'racks':[{'part_id':'rack01','position_m':[0,0,0],'frame':'rack.exterior','servers':servers}],'available_server_slots_ou':list(range(1,36,2)),'rack_slot_pitch_m':.048,'rack_slot_base_m':.18,'equipment_front_y_m':-.4,'question_intent_schema':{'action':'inspect','asset_id':'one of manifest assets','server_id':'rack01.server01','part_id':'optional refdes or stable part ID'},'source_master':'../datacenter-rack-v002.blend','limits':['Exterior mesh is a distance LOD, not metrology geometry.','VR frame rate, physics and headset integration have not been tested.','Processor internals and installed RDIMMs have explicit explanatory/class-analogue status.']}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
# Write runtime-side metadata separately; geometry is never needed to retrieve facts.
knowledge={o['part_id']:{k:o[k] for k in o.keys() if isinstance(o[k],(str,int,float,bool))} for o in source_objects if 'part_id' in o}
(OUT/'part-knowledge.json').write_text(json.dumps(knowledge,separators=(',',':')))
bpy.data.libraries.write(str(OUT/'exterior-library.blend'),{servercol},path_remap='RELATIVE_ALL',fake_user=True,compress=True)

# Remove every high-detail object, mesh and scene from the DEFAULT file only.
retained=set(rackcol.objects)|set(servercol.objects)
for c in scene.collection.children:
    if '/ studio' in c.name:retained.update(c.objects)
to_remove=[o for o in bpy.data.objects if o not in retained]
bpy.data.batch_remove(ids=to_remove)
for s in list(bpy.data.scenes):
    if s!=scene:bpy.data.scenes.remove(s)
for c in list(bpy.data.collections):
    if c not in [rackcol,servercol] and c not in list(scene.collection.children):bpy.data.collections.remove(c)
for t in list(bpy.data.texts):bpy.data.texts.remove(t)
for path in [ROOT/'source/lazy_inspector.py',ROOT/'docs/HACKATHON_PROCESS.md']:
    if path.exists():bpy.data.texts.load(str(path))
bpy.data.orphans_purge(do_recursive=True)
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type=='VIEW_3D':
            space=area.spaces.active;space.shading.type='SOLID';space.shading.color_type='MATERIAL';space.overlay.show_extras=False;space.overlay.show_relationship_lines=False;space.overlay.show_floor=False;space.clip_start=.0001
            space.region_3d.view_perspective='CAMERA';space.region_3d.view_camera_zoom=0
for o in scene.objects:o.select_set(False)
bpy.context.view_layer.objects.active=None
dest=OUT/'rack-exterior.blend';bpy.ops.wm.save_as_mainfile(filepath=str(dest),compress=True)
receipt={'schema':'rack-exterior-package/v1','initial_file_bytes':dest.stat().st_size,'detail_library_bytes':library.stat().st_size,'initial_objects':len(bpy.data.objects),'initial_meshes':len(bpy.data.meshes),'initial_scenes':[s.name for s in bpy.data.scenes],'loaded_detail_collections':[c.name for c in bpy.data.collections if c.name.startswith('DETAIL')],'server_exterior':exterior_receipt,'rack_groups':frame_receipts,'seconds':time.monotonic()-started}
(OUT/'package-receipt.json').write_text(json.dumps(receipt,indent=2));print('LAZY_PACKAGE_COMPLETE',json.dumps(receipt),flush=True)
