import bpy,sys,json,pathlib
from mathutils import Vector
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack')
TEST=BASE/'research/lazy-inspector-tests';TEST.mkdir(exist_ok=True)
sys.path.insert(0,str(BASE/'source'))
import lazy_inspector as ll
checks={}
def check(name,condition):
 assert condition,name
 checks[name]=True

def mesh(name):
 data=bpy.data.meshes.new(name);data.from_pydata([(x*.02,y*.03,z*.01) for x in [-1,1] for y in [-1,1] for z in [-1,1]],[],[(0,1,3,2),(4,6,7,5)]);data.update();return data
# Produce four independent saved collections, then remove every one from memory.
bpy.ops.wm.read_factory_settings(use_empty=True)
assets=[];collections=set()
for asset in ll.ASSET_IDS:
 col=bpy.data.collections.new('DETAIL · '+asset);root=bpy.data.objects.new(asset+'.root',None);col.objects.link(root);root['part_id']=asset+'.root';root['assembly']=True
 part=bpy.data.objects.new(asset+'.part',mesh(asset+'.mesh'));col.objects.link(part);part.parent=root;part['part_id']='pcb.U14' if asset=='server.motherboard' else asset+'.part';part['refdes']='U14' if asset=='server.motherboard' else ''
 collections.add(col);assets.append({'asset_id':asset,'collection':col.name,'library':'fixture-parts.blend','description':'Explicit isolated test fixture'})
bpy.data.libraries.write(str(TEST/'fixture-parts.blend'),collections)
(TEST/'manifest.json').write_text(json.dumps({'assets':assets},indent=2))
bpy.ops.wm.read_factory_settings(use_empty=True)
scene=bpy.context.scene;scene.name='Rack exterior';template=bpy.data.collections.new(ll.RACK_TEMPLATE);scene.collection.children.link(template)
rack=bpy.data.objects.new('rack01',None);template.objects.link(rack);rack['part_id']='rack01';rack['rack_id']='rack01'
exterior=bpy.data.collections.new(ll.EXTERIOR);part=bpy.data.objects.new('closed shell',mesh('Exterior only mesh'));exterior.objects.link(part);part['part_id']='exterior.shell'
for i,ou in enumerate(range(1,36,2),1):
 server=bpy.data.objects.new(f'rack01.server{i:02d}',None);template.objects.link(server);server.parent=rack;server.location=(0,-.4,.18+(ou-1)*.048)
 for k,v in {'part_id':server.name,'server_id':server.name,'asset_id':'server.exterior','slot_ou':ou,'rack_id':'rack01'}.items():server[k]=v
 child=bpy.data.objects.new(server.name+'.closed',None);template.objects.link(child);child.parent=server;child.instance_type='COLLECTION';child.instance_collection=exterior;child['part_id']=child.name;child['server_id']=server.name
bpy.context.view_layer.update();initial_meshes=len(bpy.data.meshes);ll.register();ll.state().manifest_path=str(TEST/'manifest.json')
check('registration_appends_nothing',len(bpy.data.meshes)==initial_meshes and ll.state().loaded_assets==0)
check('initial_one_rack_18_servers',ll.state().rack_count==1 and ll.state().server_count==18)
bpy.ops.wm.save_as_mainfile(filepath=str(TEST/'exterior-fixture.blend'))
server1=ll.find_server('rack01.server01');server2=ll.find_server('rack01.server02')
r=ll.handle_intent({'action':'inspect','asset_id':'server.mechanical','server_id':server1['part_id']});print('FIRST',r)
check('first_request_loads_only_mechanical',r['status']=='loaded' and not r['cache_hit'] and ll.state().loaded_assets==1 and len(bpy.data.meshes)==initial_meshes+1)
check('first_request_hides_exterior',all(o.hide_render for o in ll.exterior_objects(server1)))
check('whole_asset_has_no_arbitrary_selection',bpy.context.active_object is None)
check('service_parts_selectable',any(o.get('part_id')=='server.mechanical.part' for o in bpy.context.scene.objects))
check('back_to_rack',ll.handle_intent({'action':'show_rack'})['status']=='shown' and bpy.context.scene==scene)
check('back_restores_exterior',all(not o.hide_render for o in ll.exterior_objects(server1)))
r=ll.handle_intent({'action':'inspect','asset_id':'server.mechanical','server_id':server2['part_id']})
check('second_server_reuses_cache',r['cache_hit'] and len(bpy.data.meshes)==initial_meshes+1)
check('question_context_tracks_server2',bpy.context.scene.get('lazy_selected_server_id')=='rack01.server02')
r=ll.handle_intent({'action':'inspect','asset_id':'server.motherboard','server_id':server2['part_id'],'part_id':'pcb.U14'})
check('motherboard_only_on_request',r['status']=='loaded' and ll.state().loaded_assets==2 and len(bpy.data.meshes)==initial_meshes+2)
check('semantic_part_selected',r['part_status']=='found' and bpy.context.active_object.get('part_id')=='pcb.U14')
check('memory_and_processor_absent',ll.cached('server.memory') is None and ll.cached('processor.study') is None)
ll.handle_intent({'action':'show_rack'});ll.remove_server(ll.find_server('rack01.server18'))
check('remove_server_preserves_data',ll.state().server_count==17 and len(bpy.data.meshes)==initial_meshes+2)
added=ll.add_server(rack_id='rack01',slot_ou=35)
check('add_server_reuses_exterior',added['part_id']=='rack01.server18' and ll.state().server_count==18 and len(bpy.data.meshes)==initial_meshes+2)
mesh_before=len(bpy.data.meshes);newrack=ll.add_rack()
check('add_rack_linked_meshes',newrack['part_id']=='rack02' and ll.state().rack_count==2 and ll.state().server_count==36 and len(bpy.data.meshes)==mesh_before)
check('rack_spacing',abs(newrack.matrix_world.translation.x-1.1)<1e-5)
check('rack2_unique_server_ids',len({o['part_id'] for o in ll.all_servers()})==36)
check('rack2_server_context_ids',all(o.get('server_id','').startswith('rack02.') for o in bpy.data.objects if o.get('rack_id')=='rack02' and o.get('server_id')))
check('new_rack_no_detail_instances',not any(o.get('_lazy_detail_instance') and o.get('rack_id')=='rack02' for o in bpy.data.objects))
ll.unload_server(server2);removed=ll.unload_unused()
check('shared_mechanical_retained',ll.cached('server.mechanical') is not None)
check('unused_board_unloaded',ll.cached('server.motherboard') is None)
ll.unload_server(server1);ll.unload_unused()
check('all_detail_unloaded',ll.state().loaded_assets==0 and len(bpy.data.meshes)==initial_meshes)
r=ll.handle_intent({'action':'inspect','asset_id':'processor.study','server_id':server1['part_id']})
check('processor_standalone_lazy',r['status']=='loaded' and bpy.context.scene.lazy_lab.processor and ll.state().loaded_assets==1)
check('structured_unload_action',ll.handle_intent({'action':'unload','server_id':server1['part_id']})['status']=='unloaded')
check('processor_unload_returns_exterior',ll.state().loaded_assets==0)
check('unknown_action_rejected',ll.handle_intent({'action':'invent'})['status']=='error')
check('no_unrequested_source_collections',not any(c.get('_lazy_asset_id') for c in bpy.data.collections))
(TEST/'smoke-results.json').write_text(json.dumps({'checks':checks,'blender':bpy.app.version_string,'initial_meshes':initial_meshes,'final_meshes':len(bpy.data.meshes)},indent=2))
print('LAZY_SMOKE',json.dumps(checks))
