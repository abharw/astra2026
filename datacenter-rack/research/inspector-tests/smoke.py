import bpy,sys,pathlib,json,math
from mathutils import Matrix,Vector
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack')
sys.path.insert(0,str(BASE/'source'));import rack_inspector as ri
ri.register()
checks={}
def check(name,condition):
    assert condition,name
    checks[name]=True

def activate(obj):
    for o in bpy.context.selected_objects:o.select_set(False)
    obj.hide_set(False);obj.select_set(True);bpy.context.view_layer.objects.active=obj

def worlds(objects):return {o.name:ri.flat(o.matrix_world) for o in objects}
def close(a,b):return max(abs(x-y) for x,y in zip(a,b))<1e-5

def create(name,parent=None):
    obj=bpy.data.objects.new(name,None);bpy.context.scene.collection.objects.link(obj);obj.parent=parent;obj['part_id']=name;return obj

if '--reopen' in sys.argv:
    expected=json.loads(bpy.context.scene['smoke_expected'])
    check('saved_transform_state_loaded',len(bpy.context.scene.rack_lab.transforms)==4)
    check('saved_isolation_state_loaded',bpy.context.scene.rack_lab.isolate_active)
    check('renamed_pointer_loaded',any(r.obj and r.obj.name=='fixture.leaf.renamed' for r in bpy.context.scene.rack_lab.transforms))
    check('restore_after_reopen',bpy.ops.racklab.restore()=={'FINISHED'})
    for name,values in expected.items():check('world_restored_'+name,close(ri.flat(bpy.data.objects[name].matrix_world),values))
    check('show_all_after_reopen',bpy.ops.racklab.show_all()=={'FINISHED'})
    check('prior_hidden_stays_hidden',bpy.data.objects['fixture.pre_hidden'].hide_get())
    check('prior_visible_restored',not bpy.data.objects['fixture.outside'].hide_get())
    check('parents_preserved',bpy.data.objects['fixture.leaf.renamed'].parent==bpy.data.objects['fixture.child'])
else:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    root=create('fixture.assembly');root['assembly']=True;root.location=(2,-1,.5);root.rotation_euler=(.15,.1,.4);root.scale=(1.2,1.2,1.2)
    child=create('fixture.child',root);child['assembly']=True;child.location=(.1,.2,.3);child.rotation_euler=(.2,0,.1)
    leaf=create('fixture.leaf',child);leaf.location=(.04,.08,.02);leaf['cad_name']='CPU retainer';leaf['refdes']='U42';leaf['MPN']='TEST-123';leaf['description']='Known test part'
    second=create('fixture.second',root);second.location=(-.2,.1,.4)
    outside=create('fixture.outside');hidden=create('fixture.pre_hidden');hidden.hide_set(True)
    data=bpy.data.curves.new('fixture.cable','CURVE');data.dimensions='3D';sp=data.splines.new('POLY');sp.points.add(1);sp.points[0].co=(0,0,0,1);sp.points[1].co=(1,0,0,1)
    cable=bpy.data.objects.new('fixture.cable',data);bpy.context.scene.collection.objects.link(cable)
    bpy.context.view_layer.update();original=worlds([root,child,leaf,second]);parent=leaf.parent
    activate(leaf);bpy.context.scene.rack_lab.query='test-123 u42'
    check('metadata_search',bpy.ops.racklab.search()=={'FINISHED'} and bpy.context.scene.rack_lab.total_matches==1)
    check('result_pointer',bpy.context.scene.rack_lab.results[0].obj==leaf)
    check('owning_assembly',bpy.ops.racklab.select_assembly()=={'FINISHED'} and bpy.context.active_object==child)
    activate(root);check('explode_operator',bpy.ops.racklab.explode()=={'FINISHED'})
    check('world_changed',not close(ri.flat(child.matrix_world),original[child.name]))
    check('parents_unchanged_during_explode',leaf.parent==parent)
    leaf.parent=None;leaf.location=(8,9,10)
    check('restore_operator',bpy.ops.racklab.restore()=={'FINISHED'})
    for obj in [root,child,leaf,second]:check('world_restored_'+obj.name,close(ri.flat(obj.matrix_world),original[obj.name]))
    check('manual_parent_change_restored',leaf.parent==parent)
    activate(root);check('isolate_operator',bpy.ops.racklab.isolate()=={'FINISHED'})
    check('unrelated_hidden',outside.hide_get())
    check('descendant_visible',not leaf.hide_get())
    check('show_all_operator',bpy.ops.racklab.show_all()=={'FINISHED'})
    check('prior_hidden_preserved',hidden.hide_get())
    check('prior_visible_restored',not outside.hide_get())
    activate(cable);check('curve_edit',bpy.ops.racklab.edit_curve()=={'FINISHED'} and bpy.context.mode=='EDIT_CURVE');bpy.ops.object.mode_set(mode='OBJECT')
    activate(root);bpy.ops.racklab.explode();bpy.ops.racklab.isolate()
    leaf.name='fixture.leaf.renamed';original[leaf.name]=original.pop('fixture.leaf')
    bpy.context.scene['smoke_expected']=json.dumps(original)
    bpy.ops.wm.save_as_mainfile(filepath=str(BASE/'research/inspector-tests/state-roundtrip.blend'))
    check('roundtrip_state_saved',True)
    ri.unregister();ri.register();check('register_unregister_cycle',hasattr(bpy.context.scene,'rack_lab'))
name='reopen-results.json' if '--reopen' in sys.argv else 'smoke-results.json'
(BASE/'research/inspector-tests'/name).write_text(json.dumps({'checks':checks,'blender':bpy.app.version_string},indent=2))
print('INSPECTOR_SMOKE',json.dumps(checks))
