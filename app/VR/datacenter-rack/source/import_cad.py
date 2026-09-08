"""Create editable Blender objects from the preserved XCAF mesh derivative.

Run inside Blender. No source model deletion. SI meters throughout. Every CAD
assembly occurrence has an object and parent; repeated parts share mesh data.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import sys
import time

import bpy
import numpy as np
from mathutils import Matrix,Vector

PROJECT=Path(__file__).resolve().parents[1]

def cad_material(rgba,name='CAD',appearance=False):
    key=name+'_'+hashlib.sha256(str(rgba).encode()).hexdigest()[:10]
    m=bpy.data.materials.get(key)
    if m:return m
    m=bpy.data.materials.new(key);m.diffuse_color=rgba;m.use_nodes=True
    bsdf=m.node_tree.nodes.get('Principled BSDF');bsdf.inputs['Base Color'].default_value=rgba
    bsdf.inputs['Roughness'].default_value=.32;bsdf.inputs['Metallic'].default_value=.25 if appearance else 0
    m['appearance_status']='CAD display color; physical finish not yet reconstructed'
    return m

def load_cad(folder,collection=None):
    folder=Path(folder);idx=json.loads((folder/'assembly.json').read_text())
    if idx['status']!='complete':raise RuntimeError('Mesh derivative is not complete')
    if collection is None:
        collection=bpy.data.collections.new('Barreleye G2 EVT — source CAD');bpy.context.scene.collection.children.link(collection)
    data={};definitions={d['label']:d for d in idx['definitions']};objects={};t=time.monotonic()
    for d in idx['definitions']:
        if 'mesh_path' not in d:continue
        a=np.load(folder/d['mesh_path']);verts=a['vertices'];faces=a['triangles']
        mesh=bpy.data.meshes.new(d['id']+'_'+d['name']);mesh.vertices.add(len(verts));mesh.vertices.foreach_set('co',verts.reshape(-1))
        mesh.loops.add(faces.size);mesh.loops.foreach_set('vertex_index',faces.reshape(-1))
        mesh.polygons.add(len(faces));mesh.polygons.foreach_set('loop_start',np.arange(0,faces.size,3,dtype=np.int32));mesh.polygons.foreach_set('loop_total',np.full(len(faces),3,dtype=np.int32))
        for rgba in a['palette']:mesh.materials.append(cad_material(tuple(float(v) for v in rgba)))
        mesh.polygons.foreach_set('material_index',a['material_indices'].astype(np.int32))
        mesh.polygons.foreach_set('use_smooth',np.ones(len(faces),dtype=bool));mesh.update()
        mesh['cad_definition_id']=d['label'];mesh['source_mesh_sha256']=d['mesh_sha256'];mesh['tessellation_mm']=idx['deflection_mm']
        data[d['label']]=mesh
    for n in idx['nodes']:
        definition=definitions.get(n['definition_id'])
        obj=bpy.data.objects.new('cad.'+n['id']+'.'+n['definition_name'],data.get(n['definition_id']) if not n['assembly'] else None)
        collection.objects.link(obj);objects[n['id']]=obj
        if n['parent']:obj.parent=objects[n['parent']]
        obj.matrix_local=Matrix(n['matrix_local_m'])
        if obj.type=='EMPTY':obj.empty_display_type='PLAIN_AXES';obj.empty_display_size=.006
        obj['part_id']='server.cad.'+n['id'];obj['cad_label']=n['label'];obj['cad_definition_id']=n['definition_id'];obj['cad_name']=n['definition_name'];obj['cad_occurrence_name']=n['name']
        obj['source_sha256']=idx['source_sha256'];obj['source_revision']='Barreleye G2 detailed EVT STEP 2017-03-10';obj['evidence_level']='published-CAD-derived';obj['assembly']=n['assembly']
        obj['source_url']='https://github.com/opencomputeproject/zaius-barreleye-g2/tree/master/HW/ME/EVT'
        obj['description']='Published mechanical assembly occurrence: '+n['definition_name']
    bpy.context.view_layer.update()
    lo=Vector((float('inf'),)*3);hi=Vector((float('-inf'),)*3)
    bounds=[]
    for obj in objects.values():
        if obj.type!='MESH':continue
        corners=[obj.matrix_world@Vector(c) for c in obj.bound_box]
        mn=[min(c[i] for c in corners) for i in range(3)];mx=[max(c[i] for c in corners) for i in range(3)]
        for i in range(3):lo[i]=min(lo[i],mn[i]);hi[i]=max(hi[i],mx[i])
        bounds.append({'part_id':obj['part_id'],'name':obj.name,'cad_name':obj['cad_name'],'bounds_m':[mn,mx],'matrix_world_m':[list(r) for r in obj.matrix_world]})
    report={'schema':'blender-cad-import/v1','source_sha256':idx['source_sha256'],'blender_version':bpy.app.version_string,'occurrences':len(objects),'unique_meshes':len(data),'world_bounds_m':[list(lo),list(hi)],'bounds_note':'transformed local AABB envelopes; exact vertex bounds checked separately','parts':bounds,'seconds':time.monotonic()-t}
    return {'collection':collection,'objects':objects,'roots':[objects[n['id']] for n in idx['nodes'] if n['parent'] is None],'report':report}

def area_light(name,position,target,power,size,color):
    light=bpy.data.lights.new(name,'AREA');light.energy=power;light.shape='DISK';light.size=size;light.color=color
    obj=bpy.data.objects.new(name,light);bpy.context.scene.collection.objects.link(obj);obj.location=position;obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler();return obj

def preview_setup(bounds):
    lo,hi=map(Vector,bounds);center=(lo+hi)/2;extent=hi-lo;diag=extent.length
    c=bpy.data.cameras.new('CAD inspection camera');o=bpy.data.objects.new('CAD inspection camera',c);bpy.context.scene.collection.objects.link(o)
    o.location=center+Vector((1.1,-1.4,1.3))*diag;o.rotation_euler=(center-o.location).to_track_quat('-Z','Y').to_euler();c.type='ORTHO';c.ortho_scale=max(extent)*1.6;c.clip_start=.0001;c.clip_end=100;bpy.context.scene.camera=o
    for area in bpy.context.screen.areas if bpy.context.screen else []:
        if area.type=='VIEW_3D':
            area.spaces.active.region_3d.view_distance=diag*1.4;area.spaces.active.region_3d.view_location=center
            area.spaces.active.clip_start=.0001;area.spaces.active.clip_end=100
    scene=bpy.context.scene;scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=1;scene.render.engine='BLENDER_WORKBENCH';scene.render.resolution_x=1600;scene.render.resolution_y=1200;scene.render.resolution_percentage=100
    scene.display.shading.light='STUDIO';scene.display.shading.color_type='MATERIAL';scene.display.shading.show_cavity=True;scene.display.shading.cavity_type='BOTH';scene.display.shading.show_shadows=True;scene.display.shading.show_specular_highlight=True;scene.display.shading.background_type='WORLD';scene.world.color=(.06,.06,.06)

if __name__=='__main__':
    args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    p=argparse.ArgumentParser();p.add_argument('--mesh-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--render',action='store_true');a=p.parse_args(args)
    # Only fresh factory-startup jobs invoke this CLI path.
    bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
    r=load_cad(a.mesh_dir);preview_setup(r['report']['world_bounds_m']);a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.with_suffix('.json').write_text(json.dumps(r['report'],indent=2));bpy.ops.wm.save_as_mainfile(filepath=str(a.output),compress=True)
    if a.render:
        bpy.context.scene.render.filepath=str(a.output.with_suffix('.png'));bpy.ops.render.render(write_still=True)
    print(json.dumps({k:v for k,v in r['report'].items() if k!='parts'}))
