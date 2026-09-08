import bpy,sys,pathlib,json
from mathutils import Matrix
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack')
sys.path.insert(0,str(BASE/'source'));import rack_inspector as ri
bpy.ops.wm.read_factory_settings(use_empty=True);ri.register();scene=bpy.context.scene;scene.name='01 · Full rack'
checks={}
def check(name,value):assert value,name;checks[name]=True
library=bpy.data.collections.new('fixture library');library.instance_offset=(1,0,0)
mesh=bpy.data.meshes.new('test mesh');mesh.from_pydata([(x,y,z) for x in [-1,1] for y in [-1,1] for z in [-1,1]],[],[]);mesh.update()
part=bpy.data.objects.new('fixture part',mesh);library.objects.link(part);part.matrix_world=Matrix.Translation((2,0,0));part['part_id']='fixture.part'
inst=bpy.data.objects.new('fixture instance',None);scene.collection.objects.link(inst);inst.instance_type='COLLECTION';inst.instance_collection=library;inst.matrix_world=Matrix.Translation((10,20,30))@Matrix.Scale(2,4);inst['part_id']='fixture.instance';inst['service_scene']='02 · Open server';inst.select_set(True);bpy.context.view_layer.objects.active=inst;bpy.context.view_layer.update()
lo,hi=ri.instance_bounds(inst)
check('instance_transformed_min',max(abs(a-b) for a,b in zip(lo,(10,18,28)))<1e-5)
check('instance_transformed_max',max(abs(a-b) for a,b in zip(hi,(14,22,32)))<1e-5)
container=bpy.data.collections.new('fixture container');nested=bpy.data.objects.new('nested',None);container.objects.link(nested);nested.instance_type='COLLECTION';nested.instance_collection=library;nested.matrix_world=Matrix.Translation((0,5,0));inst.instance_collection=container;bpy.context.view_layer.update()
lo,hi=ri.instance_bounds(inst)
check('nested_instance_min',max(abs(a-b) for a,b in zip(lo,(10,28,28)))<1e-5)
check('nested_instance_max',max(abs(a-b) for a,b in zip(hi,(14,32,32)))<1e-5)
studio=bpy.data.collections.new(scene.name+' / studio');scene.collection.children.link(studio);floor=bpy.data.objects.new(scene.name+' floor',mesh);studio.objects.link(floor);floor['part_id']='fixture.floor'
scene.rack_lab.query='fixture';bpy.ops.racklab.search();check('studio_floor_excluded',all(row.obj!=floor for row in scene.rack_lab.results));check('instance_searchable',any(row.obj==inst for row in scene.rack_lab.results))
service=bpy.data.scenes.new('02 · Open server');bpy.data.scenes.new('03 · Motherboard fabrication')
camera_data=bpy.data.cameras.new('service camera');camera=bpy.data.objects.new('service camera',camera_data);service.collection.objects.link(camera);service.camera=camera
viewarea=next(a for a in bpy.context.screen.areas if a.type=='VIEW_3D');viewarea.spaces.active.overlay.show_extras=False;viewarea.spaces.active.overlay.show_relationship_lines=False;viewarea.spaces.active.overlay.show_floor=False
check('processor_link_absent',not any(bpy.data.scenes.get(name) for name,label in ri.SCENE_LINKS if label=='Processor'))
check('inspect_server_operator',bpy.ops.racklab.inspect_server()=={'FINISHED'} and bpy.context.window.scene==service)
check('scene_camera_view',viewarea.spaces.active.camera==camera and viewarea.spaces.active.region_3d.view_perspective=='CAMERA')
check('overlays_preserved',not viewarea.spaces.active.overlay.show_extras and not viewarea.spaces.active.overlay.show_relationship_lines and not viewarea.spaces.active.overlay.show_floor)
check('rack_scene_operator',bpy.ops.racklab.open_scene(scene_name='01 · Full rack')=={'FINISHED'} and bpy.context.window.scene==scene)
# In background Blender the default screen still exposes a VIEW_3D context.
area=next((a for a in bpy.context.screen.areas if a.type=='VIEW_3D'),None)
if area:
 region=next(r for r in area.regions if r.type=='WINDOW');before=set(bpy.data.objects);before_meshes=set(bpy.data.meshes)
 with bpy.context.temp_override(area=area,region=region):result=bpy.ops.racklab.frame()
 check('frame_instance_operator',result=={'FINISHED'})
 check('temporary_objects_removed',set(bpy.data.objects)==before and set(bpy.data.meshes)==before_meshes)
 check('frame_selection_preserved',bpy.context.view_layer.objects.active==inst and list(bpy.context.selected_objects)==[inst])
 check('frame_uses_instance_extent',area.spaces.active.region_3d.view_distance>4)
else:checks['frame_context_unavailable']=False
(BASE/'research/inspector-tests/navigation-results.json').write_text(json.dumps({'checks':checks,'blender':bpy.app.version_string},indent=2))
print('NAVIGATION_SMOKE',json.dumps(checks))
