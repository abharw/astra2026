import bpy,sys,json,pathlib
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack');TEST=BASE/'research/lazy-inspector-tests';sys.path.insert(0,str(BASE/'source'));import lazy_inspector as ll
checks={}
def check(name,value):assert value,name;checks[name]=True
before=len(bpy.data.meshes);ll.register();ll.state().manifest_path=str(TEST/'manifest.json')
check('registration_does_not_append',len(bpy.data.meshes)==before)
if '--reopen' in sys.argv:
 check('cache_recovered_without_library_load',ll.state().loaded_assets==2)
 server=ll.find_server('rack01.server01');check('saved_server_asset_state',len(server.lazy_lab.assets)==2)
 result=ll.handle_intent({'action':'inspect','asset_id':'server.motherboard','server_id':'rack01.server01','part_id':'pcb.U14'})
 check('reopen_reuses_cache',result['cache_hit'] and len(bpy.data.meshes)==before)
 check('saved_part_reselected',result['part_status']=='found')
 check('back_restores_saved_exterior',ll.handle_intent({'action':'show_rack'})['status']=='shown' and all(not o.hide_render for o in ll.exterior_objects(server)))
 ll.unload_server(server);ll.unload_unused();check('reopened_imports_can_unload',ll.state().loaded_assets==0 and len(bpy.data.meshes)==1)
else:
 check('initial_file_has_no_detail',ll.state().loaded_assets==0 and before==1)
 for asset in ['server.mechanical','server.motherboard']:
  result=ll.handle_intent({'action':'inspect','asset_id':asset,'server_id':'rack01.server01'});check(asset+'_loaded',result['status']=='loaded')
 bpy.ops.wm.save_as_mainfile(filepath=str(TEST/'inspection-fixture.blend'))
name='persistence-reopen-results.json' if '--reopen' in sys.argv else 'persistence-save-results.json'
(TEST/name).write_text(json.dumps(checks,indent=2));print('PERSISTENCE',json.dumps(checks))
