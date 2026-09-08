import bpy,bmesh,sys,json,math,pathlib,datetime
from mathutils import Vector
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack')
sys.path.insert(0,str(BASE/'source'));import rack_frame
# This isolated background process owns a clean temporary scene. The module itself never deletes anything.
bpy.ops.wm.read_factory_settings(use_empty=True)
r=rack_frame.build_rack();bpy.context.view_layer.update()
objs=[o for col in r['collections'].values() for o in col.objects]
missing=[o.name for o in objs if any(not o.get(k) for k in ['part_id','source_url','evidence_level','description'])]
def bbox(o):
 pts=[o.matrix_world@Vector(p) for p in o.bound_box]
 return {'min':[min(v[i] for v in pts) for i in range(3)],'max':[max(v[i] for v in pts) for i in range(3)]}
frame=[o for o in objs if o.name.startswith('rack.frame.') and o.type=='MESH']
bs=[bbox(o) for o in frame];lo=[min(t['min'][i] for t in bs) for i in range(3)];hi=[max(t['max'][i] for t in bs) for i in range(3)]
rep={'time':datetime.datetime.now(datetime.timezone.utc).isoformat(),'blender_version':bpy.app.version_string,'objects':len(objs),'mesh_objects':sum(o.type=='MESH' for o in objs),'mesh_vertices':sum(len(o.data.vertices) for o in objs if o.type=='MESH'),'metadata_missing':missing,'frame_bounds':{'min':lo,'max':hi,'size':[hi[i]-lo[i] for i in range(3)]},'psu_01_origin':list(bpy.data.objects['rack.psu.01.assembly'].matrix_world.translation),'shelf_origin':list(bpy.data.objects['rack.power_shelf.assembly'].matrix_world.translation),'psu_01_lid_bbox':bbox(bpy.data.objects['rack.psu.01.lid']),'anchors':r['anchors'],'geometric_interoperability':'pending_root_CAD_mating_check','checks':{}}
perforations={}
for o in objs:
 if o.type=='MESH' and (o.name.endswith('latch_web') or o.name.endswith('screw_web') or o.name.endswith('mounting_flange')):
  bm=bmesh.new();bm.from_mesh(o.data);perforations[o.name]={'non_manifold_edges':sum(not e.is_manifold for e in bm.edges)};bm.free()
rep['perforation_meshes']=perforations
rep['checks']['closed_manifold_perforated_sheets']=all(x['non_manifold_edges']==0 for x in perforations.values())
rep['checks']['all_names_rack_prefix']=all(o.name.startswith('rack.') for o in objs)
rep['checks']['metadata_complete']=not missing
rep['checks']['frame_width']=abs(hi[0]-lo[0]-.6)<1e-5
rep['checks']['frame_depth']=abs(hi[1]-lo[1]-1.067)<1e-5
rep['checks']['frame_top_height']=abs(hi[2]-2.21)<1e-5
rep['checks']['OU_pitch']=abs(r['server_slot_origins'][2][2]-r['server_slot_origins'][1][2]-.048)<1e-6
rep['checks']['psu_parent_origin']=abs(rep['psu_01_origin'][1]+.4)<1e-6
(BASE/'research/rack-frame/validation.json').write_text(json.dumps(rep,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(BASE/'source/rack-frame.blend'))
scene=bpy.context.scene;scene.world=bpy.data.worlds.new('rack.qa.world');scene.render.engine='BLENDER_WORKBENCH';scene.display.shading.light='STUDIO';scene.display.shading.studiolight_rotate_z=.4;scene.display.shading.color_type='SINGLE';scene.display.shading.single_color=(.52,.52,.52);scene.display.shading.show_shadows=True;scene.display.shading.show_cavity=True;scene.display.shading.cavity_type='BOTH';scene.display.shading.curvature_ridge_factor=1.1;scene.display.shading.curvature_valley_factor=1.0;scene.display.shading.background_type='WORLD';scene.world.color=(.14,.14,.14)
scene.render.image_settings.file_format='PNG';scene.render.resolution_percentage=100;scene.render.resolution_x=1200;scene.render.resolution_y=1500
camdata=bpy.data.cameras.new('rack.qa.camera');cam=bpy.data.objects.new('rack.qa.camera',camdata);scene.collection.objects.link(cam);scene.camera=cam
views=[('clay-front',(2.5,-4.4,2.8),(0,0,1.14),2.72),('clay-rear',(-2.3,4.3,2.6),(0,0,1.14),2.72),('power-close',(.60,-1.5,2.27),(0,-.15,1.91),.95),('rail-close',(.05,-.68,.78),(-.269,-.373,.72),.22),('foot-close',(-.8,-.88,.29),(-.235,-.455,.10),.35),('power-rear-close',(.6,1.4,2.4),(0,.34,1.92),.85)]
for name,pos,target,scale in views:
 cam.location=pos;cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler();camdata.type='ORTHO';camdata.ortho_scale=scale
 scene.render.filepath=str(BASE/'research/rack-frame'/f'{name}.png');bpy.ops.render.render(write_still=True)
print('VALIDATION',json.dumps(rep))
