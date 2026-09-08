import bpy,sys,pathlib,json,importlib
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack');sys.path.insert(0,str(BASE/'source'));import lazy_inspector as ll
checks={}
def check(name,value):assert value,name;checks[name]=True
before=len(bpy.data.meshes);ll.register();ll.register()
check('register_idempotent',len(bpy.data.meshes)==before and ll.state().loaded_assets==2)
check('state_survives_repeated_registration',len(ll.find_server('rack01.server01').lazy_lab.assets)==2)
ll=importlib.reload(ll);ll.register()
check('new_module_registration_preserves_state',ll.state().loaded_assets==2 and len(ll.find_server('rack01.server01').lazy_lab.assets)==2)
check('reload_never_appends',len(bpy.data.meshes)==before)
check('one_load_handler',sum(bool(getattr(h,'_lazy_lab_handler',False)) for h in bpy.app.handlers.load_post)==1)
(BASE/'research/lazy-inspector-tests/reload-results.json').write_text(json.dumps(checks,indent=2));print('RELOAD',json.dumps(checks))
