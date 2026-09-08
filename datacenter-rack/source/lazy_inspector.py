"""Rack Lab local, demand-loaded inspection. Registration never opens a library.

Semantic bridge: handle_intent({'action':'inspect','asset_id':..., 'server_id':..., 'part_id':...})
No language heuristics, network calls, automatic detail loads, or asset generation.
"""
bl_info={'name':'Rack Lab Lazy Inspection','version':(1,0,0),'blender':(4,2,0),'category':'3D View'}
import bpy,sys,json,math,datetime
from pathlib import Path
from mathutils import Matrix,Vector
from bpy.props import StringProperty,IntProperty,BoolProperty,PointerProperty,CollectionProperty,EnumProperty
from bpy.app.handlers import persistent
BASE=Path(__file__).resolve().parents[1]
MANIFEST=BASE/'models/lazy/manifest.json'
ASSET_IDS=('server.mechanical','server.motherboard','server.memory','processor.study')
EXTERIOR='EXTERIOR · server.closed'
RACK_TEMPLATE='RACK · exterior template'
RACK_ITEMS=[('rack01','Rack 01','')]
if str(BASE/'source') not in sys.path:sys.path.insert(0,str(BASE/'source'))
import rack_inspector as inspector

def log(action,**fields):
    try:
        path=BASE/'logs/lazy-inspector-actions.jsonl';path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('a') as f:f.write(json.dumps(dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),action=action,**fields),default=str)+'\n')
    except OSError:pass

def rack_items(self,context):return RACK_ITEMS

class LAZYLAB_Asset(bpy.types.PropertyGroup):
    asset_id:StringProperty()
    collection:PointerProperty(type=bpy.types.Collection)
    instance:PointerProperty(type=bpy.types.Object)

class LAZYLAB_Exterior(bpy.types.PropertyGroup):
    obj:PointerProperty(type=bpy.types.Object)
    hidden:BoolProperty()
    render_hidden:BoolProperty()

class LAZYLAB_Server(bpy.types.PropertyGroup):
    assets:CollectionProperty(type=LAZYLAB_Asset)
    exteriors:CollectionProperty(type=LAZYLAB_Exterior)

class LAZYLAB_Scene(bpy.types.PropertyGroup):
    server:PointerProperty(type=bpy.types.Object)
    rack_scene:PointerProperty(type=bpy.types.Scene)
    exterior:PointerProperty(type=bpy.types.Collection)
    service:BoolProperty()
    processor:BoolProperty()

class LAZYLAB_State(bpy.types.PropertyGroup):
    manifest_path:StringProperty(default=str(MANIFEST),subtype='FILE_PATH')
    assets:CollectionProperty(type=LAZYLAB_Asset)
    loaded_assets:IntProperty()
    object_count:IntProperty()
    mesh_count:IntProperty()
    vertex_count:IntProperty()
    server_count:IntProperty()
    rack_count:IntProperty()
    rack_target:EnumProperty(name='Rack',items=rack_items)
    add_slot:EnumProperty(name='Slot',items=[('AUTO','First available','')]+[(str(n),f'OU {n}–{n+1}','') for n in range(1,36,2)],default='AUTO')
    last_server:PointerProperty(type=bpy.types.Object)
    status:StringProperty(default='Exterior only. Load detail when needed.')

def state(context=None):return (context or bpy.context).window_manager.lazy_lab

def is_server(obj):return bool(obj and obj.get('asset_id')=='server.exterior' and obj.get('slot_ou') is not None)

def selected_server(context=None):
    context=context or bpy.context;obj=context.active_object
    while obj:
        if is_server(obj):return obj
        obj=obj.parent
    if context.scene.lazy_lab.server:return context.scene.lazy_lab.server
    return None

def all_servers():return [o for o in bpy.data.objects if is_server(o)]

def find_server(server_id=None,context=None):
    if server_id:
        matches=[o for o in all_servers() if o.get('part_id')==server_id]
        if len(matches)!=1:raise ValueError('Server ID is missing or ambiguous: '+str(server_id))
        return matches[0]
    obj=selected_server(context)
    if not obj:raise ValueError('Select a server in the rack first.')
    return obj

def find_rack_scene(server=None,context=None):
    context=context or bpy.context
    if context.scene.lazy_lab.rack_scene:return context.scene.lazy_lab.rack_scene
    if server:
        for scene in bpy.data.scenes:
            if not scene.lazy_lab.service and not scene.lazy_lab.processor and server.name in scene.objects:return scene
    for scene in bpy.data.scenes:
        if any(is_server(o) for o in scene.objects):return scene
    for scene in bpy.data.scenes:
        if any(o.get('part_id')==o.get('rack_id') and str(o.get('rack_id','')).startswith('rack') for o in scene.objects):return scene
    raise ValueError('The exterior rack scene is unavailable.')

def rack_roots(scene):
    return [o for o in scene.objects if o.get('part_id')==o.get('rack_id') and str(o.get('rack_id','')).startswith('rack')]

def refresh_stats(context=None):
    context=context or bpy.context;s=state(context);s.assets.clear();objects=set();meshes=set()
    for col in bpy.data.collections:
        if col.get('_lazy_asset_id'):
            row=s.assets.add();row.asset_id=col['_lazy_asset_id'];row.collection=col
            objects.update(col.all_objects)
    meshes={o.data for o in objects if o.type=='MESH'}
    s.loaded_assets=len(s.assets);s.object_count=len(objects);s.mesh_count=len(meshes);s.vertex_count=sum(len(m.vertices) for m in meshes)
    servers=all_servers();s.server_count=len(servers)
    ids=sorted({str(o.get('rack_id')) for o in bpy.data.objects if o.get('part_id')==o.get('rack_id') and str(o.get('rack_id','')).startswith('rack')})
    if not ids:ids=sorted({str(o.get('rack_id','rack01')) for o in servers}) or ['rack01']
    global RACK_ITEMS
    RACK_ITEMS=[(key,'Rack '+key.removeprefix('rack'),'') for key in ids];s.rack_count=len(ids)
    return {'loaded_assets':s.loaded_assets,'objects':s.object_count,'meshes':s.mesh_count,'vertices':s.vertex_count,'servers':s.server_count,'racks':s.rack_count}

def manifest(context=None):
    path=Path(bpy.path.abspath(state(context).manifest_path)).expanduser()
    if not path.is_file():raise FileNotFoundError('Saved asset manifest is not available: '+str(path))
    data=json.loads(path.read_text());raw=data.get('assets',{})
    records={row['asset_id']:row for row in raw} if isinstance(raw,list) else {key:dict(value,asset_id=value.get('asset_id',key)) for key,value in raw.items()}
    return path,data,records

def cached(asset_id):
    return next((c for c in bpy.data.collections if c.get('_lazy_asset_id')==asset_id),None)

def load_saved_asset(asset_id,context=None,trail=()):
    if asset_id not in ASSET_IDS:raise ValueError('Unsupported saved asset: '+str(asset_id))
    if asset_id in trail:raise ValueError('Circular asset dependencies in manifest.')
    existing=cached(asset_id)
    if existing:return existing,True
    path,data,records=manifest(context)
    if asset_id not in records:raise ValueError('Asset is absent from manifest: '+asset_id)
    record=records[asset_id]
    for dependency in record.get('dependencies',[]):load_saved_asset(dependency,context,trail+(asset_id,))
    library=Path(record.get('library',data.get('library','parts-library.blend')))
    if not library.is_absolute():library=path.parent/library
    library=library.resolve()
    if not library.is_file():raise FileNotFoundError('Saved parts library is unavailable: '+str(library))
    collection_name=record['collection'];kinds=('collections','objects','meshes','curves','materials','images')
    before={kind:set(getattr(bpy.data,kind)) for kind in kinds}
    # Only the requested named collection is appended, on this explicit request.
    with bpy.data.libraries.load(str(library),link=False) as (source,target):
        if collection_name not in source.collections:raise ValueError('Collection missing from library: '+collection_name)
        target.collections=[collection_name]
    collection=target.collections[0]
    if collection is None:raise RuntimeError('Blender did not append the requested collection.')
    for kind in kinds:
        for item in set(getattr(bpy.data,kind))-before[kind]:item['_lazy_imported']=True
    collection['_lazy_asset_id']=asset_id;collection['_lazy_source_library']=str(library);collection['_lazy_description']=record.get('description','')
    stats=refresh_stats(context);log('append_saved_collection',asset_id=asset_id,collection=collection.name,library=str(library),stats=stats)
    return collection,False

def exterior_objects(server):
    result=[]
    if server.instance_type=='COLLECTION' and server.instance_collection:result.append(server)
    result.extend(o for o in server.children if o.instance_type=='COLLECTION' and o.instance_collection and not o.get('_lazy_detail_instance'))
    return result

def hide_exterior(server,rack_scene):
    saved=server.lazy_lab.exteriors;layer=rack_scene.view_layers[0]
    if not saved:
        for obj in exterior_objects(server):
            row=saved.add();row.obj=obj;row.hidden=obj.hide_get(view_layer=layer);row.render_hidden=obj.hide_render
            if obj.instance_collection:rack_scene.lazy_lab.exterior=obj.instance_collection
    for row in saved:
        if row.obj:row.obj.hide_set(True,view_layer=layer);row.obj.hide_render=True

def restore_exterior(server,rack_scene):
    layer=rack_scene.view_layers[0]
    for row in server.lazy_lab.exteriors:
        if row.obj:row.obj.hide_set(row.hidden,view_layer=layer);row.obj.hide_render=row.render_hidden
    server.lazy_lab.exteriors.clear()
    for row in server.lazy_lab.assets:
        if row.instance:
            bpy.data.objects.remove(row.instance,do_unlink=True);row.instance=None

def ensure_rack_instance(server,asset_id,collection,rack_scene):
    row=next((r for r in server.lazy_lab.assets if r.asset_id==asset_id),None)
    if row is None:row=server.lazy_lab.assets.add();row.asset_id=asset_id
    row.collection=collection
    if row.instance is None:
        obj=bpy.data.objects.new(server['part_id']+'.'+asset_id,None);obj.instance_type='COLLECTION';obj.instance_collection=collection
        target=server.users_collection[0] if server.users_collection else rack_scene.collection;target.objects.link(obj);obj.parent=server;obj.matrix_basis=Matrix.Identity(4)
        obj['part_id']=server['part_id']+'.'+asset_id;obj['asset_id']=asset_id;obj['_lazy_detail_instance']=True;obj['source_server_id']=server['part_id'];obj['server_id']=server['part_id'];obj['rack_id']=server.get('rack_id','rack01');row.instance=obj
    return row

def service_scene(server,rack_scene,processor=False):
    name='Inspect · Processor' if processor else 'Inspect · '+server['part_id']
    scene=bpy.data.scenes.get(name)
    if scene is None:scene=bpy.data.scenes.new(name);scene.world=rack_scene.world;scene.unit_settings.system='METRIC';scene.unit_settings.scale_length=1
    scene.lazy_lab.server=server;scene.lazy_lab.rack_scene=rack_scene;scene.lazy_lab.processor=processor;scene.lazy_lab.service=not processor
    scene['lazy_selected_server_id']=server['part_id']
    return scene

def link_asset(scene,collection):
    if collection.name not in scene.collection.children:scene.collection.children.link(collection)

def focus_view(context,scene,objects):
    if context.window is None:return False
    context.window.scene=scene;context.view_layer.update()
    visible=[o for o in objects if o.type in {'MESH','CURVE','SURFACE','FONT','EMPTY'} and o.name in context.view_layer.objects and o.visible_get(view_layer=context.view_layer)]
    for obj in context.selected_objects:obj.select_set(False)
    selectable=[o for o in visible if not o.hide_select]
    if selectable:
        selected=next((o for o in selectable if o.type!='EMPTY'),selectable[0]);selected.select_set(True);context.view_layer.objects.active=selected
    low=Vector((math.inf,)*3);high=Vector((-math.inf,)*3);found=False
    for obj in visible:
        if obj.type=='EMPTY':continue
        for corner in obj.bound_box:
            p=obj.matrix_world@Vector(corner);found=True
            for axis in range(3):low[axis]=min(low[axis],p[axis]);high[axis]=max(high[axis],p[axis])
    if not found:return False
    center=(low+high)*.5;extent=max(high-low)
    for area in context.window.screen.areas:
        if area.type!='VIEW_3D':continue
        space=area.spaces.active;space.shading.type='SOLID';space.shading.color_type='MATERIAL';space.shading.light='STUDIO';space.shading.show_shadows=True;space.shading.show_cavity=True
        space.overlay.show_extras=False;space.overlay.show_relationship_lines=False;space.overlay.show_floor=False
        region=space.region_3d
        if region:
            region.view_perspective='PERSP';region.view_location=center;region.view_distance=max(.025,extent*1.75);region.view_rotation=Vector((-1,1,-1.1)).to_track_quat('-Z','Y')
        space.clip_start=.0001;space.clip_end=1000;area.tag_redraw()
    return True

def resolve_part(scene,part_id):
    exact=[o for o in scene.objects if o.get('part_id')==part_id]
    if exact:return exact
    if str(part_id).startswith('pcb.'):
        ref=str(part_id)[4:];return [o for o in scene.objects if o.get('refdes')==ref or o.get('socket_refdes')==ref]
    return []

def show_rack(context=None):
    context=context or bpy.context;server=context.scene.lazy_lab.server or selected_server(context);rack=find_rack_scene(server,context)
    if server:
        restore_exterior(server,rack);rack['lazy_selected_server_id']=server['part_id']
    if context.window:
        inspector.open_inspection_scene(context,rack)
        if server and server.name in context.view_layer.objects:
            for o in context.selected_objects:o.select_set(False)
            server.select_set(True);context.view_layer.objects.active=server
    refresh_stats(context);log('show_rack',server_id=server.get('part_id') if server else None)
    return {'status':'shown','scene':rack.name}

def handle_intent(intent,context=None):
    """Apply a structured local intent on Blender's main thread; return JSON-safe result."""
    context=context or bpy.context
    try:
        if context.mode!='OBJECT':raise ValueError('Return to Object Mode before loading or switching models.')
        action=intent.get('action')
        if action=='show_rack':return show_rack(context)
        if action=='unload':
            server=find_server(intent.get('server_id'),context);server_id=server['part_id'];unload_server(server,context);removed=unload_unused(context)
            return {'status':'unloaded','server_id':server_id,'removed_assets':removed,'stats':refresh_stats(context)}
        if action!='inspect':raise ValueError('Supported intent actions are inspect, show_rack and unload.')
        asset_id=intent.get('asset_id');server=find_server(intent.get('server_id'),context);rack=find_rack_scene(server,context)
        previous=context.scene.lazy_lab.server
        if previous and previous!=server:restore_exterior(previous,find_rack_scene(previous,context))
        collection,hit=load_saved_asset(asset_id,context);processor=asset_id=='processor.study';view=service_scene(server,rack,processor)
        if processor:link_asset(view,collection)
        else:
            hide_exterior(server,rack);ensure_rack_instance(server,asset_id,collection,rack)
            for row in server.lazy_lab.assets:
                if row.collection:link_asset(view,row.collection)
        if context.window:context.window.scene=view
        view['lazy_active_asset_id']=asset_id
        context.view_layer.update()
        # Visibility is per service view layer, never a mutation of cached mesh data.
        for obj in view.objects:
            name=str(obj.get('cad_name','')).upper()
            if obj.get('inspection_role')=='lid' or 'TOP-COVER' in name:obj.hide_set(True,view_layer=view.view_layers[0])
        part_id=intent.get('part_id');matches=resolve_part(view,part_id) if part_id else []
        if len(matches)==1:
            matches[0].hide_set(False,view_layer=view.view_layers[0]);targets=inspector.descendants(matches[0]);part_status='found'
        else:targets=list(collection.all_objects);part_status='not_requested' if not part_id else ('not_found' if not matches else 'ambiguous')
        framed=focus_view(context,view,targets)
        for o in context.selected_objects:o.select_set(False)
        context.view_layer.objects.active=None
        if len(matches)==1 and not matches[0].hide_select:
            matches[0].select_set(True);context.view_layer.objects.active=matches[0]
        stats=refresh_stats(context);state(context).last_server=server;state(context).status=('Opened '+asset_id+(' from cache.' if hit else ' from saved library.'))
        result={'status':'loaded','asset_id':asset_id,'server_id':server['part_id'],'collection':collection.name,'cache_hit':hit,'scene':view.name,'part_status':part_status,'part_id':matches[0].get('part_id') if len(matches)==1 else part_id,'candidates':[o.get('part_id',o.name) for o in matches[:20]],'framed':framed,'stats':stats}
        log('inspect_saved_asset',**result);return result
    except Exception as error:
        result={'status':'error','message':str(error)};state(context).status=str(error);log('intent_error',intent=intent,message=str(error));return result

def unload_server(server,context=None):
    context=context or bpy.context;rack=find_rack_scene(server,context)
    if context.window:context.window.scene=rack
    restore_exterior(server,rack);server.lazy_lab.assets.clear();rack['lazy_selected_server_id']=server['part_id']
    if context.window:
        context.view_layer.update()
        for old in context.selected_objects:old.select_set(False)
        if server.name in context.view_layer.objects:server.select_set(True);context.view_layer.objects.active=server
    for scene in list(bpy.data.scenes):
        if (scene.lazy_lab.service or scene.lazy_lab.processor) and scene.lazy_lab.server==server:bpy.data.scenes.remove(scene,do_unlink=True)
    refresh_stats(context);log('unload_server_details',server_id=server['part_id'])

def unload_unused(context=None):
    context=context or bpy.context
    # Real collection and instance users protect cached assets; cache UI pointers do not.
    used=set()
    for scene in bpy.data.scenes:
        stack=list(scene.collection.children)
        while stack:
            col=stack.pop()
            if col in used:continue
            used.add(col);stack.extend(col.children)
    used.update(o.instance_collection for o in bpy.data.objects if o.instance_collection)
    removed=[];state(context).assets.clear()
    for col in list(bpy.data.collections):
        if col.get('_lazy_asset_id') and col not in used:
            removed.append(col['_lazy_asset_id']);bpy.data.collections.remove(col,do_unlink=True)
    # Delete only unused data imported by this add-on, never global orphan data.
    for _ in range(4):
        for kind in ('collections','objects','meshes','curves','materials','images'):
            container=getattr(bpy.data,kind)
            for item in list(container):
                if not item.get('_lazy_imported'):continue
                if item.use_fake_user and item.users==1:item.use_fake_user=False
                if item.users==0:container.remove(item)
    stats=refresh_stats(context);log('unload_unused_assets',removed=removed,stats=stats);return removed

def exterior_collection(rack):
    col=rack.lazy_lab.exterior or bpy.data.collections.get(EXTERIOR)
    if not col:
        for obj in rack.objects:
            if is_server(obj):
                candidates=exterior_objects(obj)
                if candidates:col=candidates[0].instance_collection;break
    if not col:raise ValueError('The saved server exterior collection is unavailable.')
    rack.lazy_lab.exterior=col;return col

def frame_selection(context):
    if context.window is None:return False
    for area in context.window.screen.areas:
        if area.type=='VIEW_3D':
            region=next((r for r in area.regions if r.type=='WINDOW'),None)
            if region:
                with context.temp_override(area=area,region=region):bpy.ops.racklab.frame()
                return True
    return False

def add_server(context=None,rack_id=None,slot_ou=None):
    context=context or bpy.context;rack=find_rack_scene(context=context);rack_id=rack_id or state(context).rack_target
    root=next((o for o in rack_roots(rack) if o.get('rack_id')==rack_id),None)
    if not root:raise ValueError('Select an existing rack.')
    occupied={int(o['slot_ou']) for o in rack.objects if is_server(o) and o.get('rack_id')==rack_id}
    available=[n for n in range(1,36,2) if n not in occupied]
    if slot_ou is None:
        if not available:raise ValueError('This rack is full. Remove a server or add another rack.')
        slot_ou=available[0]
    if slot_ou not in range(1,36,2) or slot_ou in occupied:raise ValueError('Choose an empty two-OU slot between OU1 and OU35.')
    col=exterior_collection(rack);server_id=f'{rack_id}.server{(slot_ou+1)//2:02d}'
    obj=bpy.data.objects.new(server_id,None);target=root.users_collection[0] if root.users_collection else rack.collection;target.objects.link(obj);obj.parent=root;obj.location=(0,-.4,.18+(slot_ou-1)*.048)
    for key,value in {'part_id':server_id,'server_id':server_id,'asset_id':'server.exterior','slot_ou':slot_ou,'rack_id':rack_id,'units':'metres','description':'Exterior server; load saved detail on request','assembly':True}.items():obj[key]=value
    instance=bpy.data.objects.new(server_id+'.closed',None);target.objects.link(instance);instance.parent=obj;instance.instance_type='COLLECTION';instance.instance_collection=col;instance['part_id']=server_id+'.closed';instance['server_id']=server_id;instance['asset_id']='server.exterior';instance['rack_id']=rack_id
    if context.window:context.window.scene=rack
    context.view_layer.update()
    for old in context.selected_objects:old.select_set(False)
    obj.select_set(True);context.view_layer.objects.active=obj;state(context).last_server=obj;rack['lazy_selected_server_id']=server_id;refresh_stats(context);log('add_server',server_id=server_id,slot_ou=slot_ou,rack_id=rack_id)
    frame_selection(context)
    return obj

def remove_server(server,context=None):
    context=context or bpy.context;rack=find_rack_scene(server,context);exterior_collection(rack);server_id=server['part_id'];unload_server(server,context)
    for obj in reversed(inspector.descendants(server)):bpy.data.objects.remove(obj,do_unlink=True)
    refresh_stats(context);log('remove_server',server_id=server_id)

def add_rack(context=None):
    context=context or bpy.context;rack=find_rack_scene(context=context)
    if context.window:context.window.scene=rack
    template=bpy.data.collections.get(RACK_TEMPLATE)
    if template is None:raise ValueError('The saved exterior rack template is unavailable.')
    roots=rack_roots(rack);source_root=next((o for o in template.all_objects if o.get('part_id')=='rack01'),None)
    if not source_root:raise ValueError('The exterior template has no rack01 root.')
    for obj in list(template.all_objects):
        if is_server(obj):restore_exterior(obj,rack)
    used={str(o.get('rack_id')) for o in roots};number=1
    while f'rack{number:02d}' in used:number+=1
    rack_id=f'rack{number:02d}';obj_map={}
    def copy_collection(source):
        destination=bpy.data.collections.new('RACK · '+rack_id if source==template else rack_id+' / '+source.name)
        for obj in source.objects:
            if obj.get('_lazy_detail_instance'):continue
            clone=obj_map.get(obj)
            if clone is None:
                clone=obj.copy();obj_map[obj]=clone;clone.name=rack_id+' / '+obj.name
                old_id=str(obj.get('part_id',obj.name));clone['part_id']=rack_id+old_id[len('rack01'):] if old_id.startswith('rack01') else rack_id+'.'+old_id
                clone['rack_id']=rack_id
                if obj.get('server_id'):clone['server_id']=rack_id+str(obj['server_id'])[len('rack01'):]
                clone.lazy_lab.assets.clear();clone.lazy_lab.exteriors.clear()
            destination.objects.link(clone)
        for child in source.children:destination.children.link(copy_collection(child))
        return destination
    new_collection=copy_collection(template);rack.collection.children.link(new_collection)
    for old,new in obj_map.items():new.parent=obj_map.get(old.parent);new.matrix_parent_inverse=old.matrix_parent_inverse.copy();new.matrix_basis=old.matrix_basis.copy()
    new_root=obj_map[source_root];new_root['part_id']=rack_id;new_root['rack_id']=rack_id
    new_root.location.x=max((o.matrix_world.translation.x for o in roots),default=0)+1.1
    context.view_layer.update();refresh_stats(context);state(context).rack_target=rack_id
    for o in context.selected_objects:o.select_set(False)
    new_root.select_set(True);context.view_layer.objects.active=new_root
    new_servers=sorted((o['part_id'] for o in all_servers() if o.get('rack_id')==rack_id))
    if new_servers:rack['lazy_selected_server_id']=new_servers[0]
    log('add_rack',rack_id=rack_id,objects=len(obj_map),mesh_data='linked to existing exterior meshes')
    frame_selection(context)
    return new_root

class LAZYLAB_OT_Inspect(bpy.types.Operator):
    bl_idname='lazyrack.inspect';bl_label='Load saved detail'
    asset_id:StringProperty()
    @classmethod
    def poll(cls,context):return context.mode=='OBJECT' and selected_server(context) is not None
    def execute(self,context):
        result=handle_intent({'action':'inspect','asset_id':self.asset_id,'server_id':selected_server(context)['part_id']},context)
        if result['status']=='error':self.report({'ERROR'},result['message']);return {'CANCELLED'}
        return {'FINISHED'}

class LAZYLAB_OT_Back(bpy.types.Operator):
    bl_idname='lazyrack.show_rack';bl_label='Back to rack'
    def execute(self,context):
        result=handle_intent({'action':'show_rack'},context)
        if result['status']=='error':self.report({'ERROR'},result['message']);return {'CANCELLED'}
        return {'FINISHED'}

class LAZYLAB_OT_Unload(bpy.types.Operator):
    bl_idname='lazyrack.unload';bl_label='Unload selected details'
    @classmethod
    def poll(cls,context):return context.mode=='OBJECT' and selected_server(context) is not None
    def execute(self,context):
        unload_server(selected_server(context),context);unload_unused(context);state(context).status='Selected details unloaded; shared assets still in use are retained.';return {'FINISHED'}

class LAZYLAB_OT_Unused(bpy.types.Operator):
    bl_idname='lazyrack.unload_unused';bl_label='Unload unused cached detail'
    def execute(self,context):
        removed=unload_unused(context);state(context).status=f'Unloaded {len(removed)} unused detail assets.';return {'FINISHED'}

class LAZYLAB_OT_AddServer(bpy.types.Operator):
    bl_idname='lazyrack.add_server';bl_label='Add server'
    def execute(self,context):
        try:add_server(context,slot_ou=None if state(context).add_slot=='AUTO' else int(state(context).add_slot));return {'FINISHED'}
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}

class LAZYLAB_OT_RemoveServer(bpy.types.Operator):
    bl_idname='lazyrack.remove_server';bl_label='Remove selected server'
    @classmethod
    def poll(cls,context):return context.mode=='OBJECT' and selected_server(context) is not None
    def execute(self,context):remove_server(selected_server(context),context);return {'FINISHED'}

class LAZYLAB_OT_AddRack(bpy.types.Operator):
    bl_idname='lazyrack.add_rack';bl_label='Add rack'
    def execute(self,context):
        try:add_rack(context);return {'FINISHED'}
        except Exception as error:self.report({'ERROR'},str(error));return {'CANCELLED'}

class LAZYLAB_PT_Main(bpy.types.Panel):
    bl_label='Equipment and detail';bl_idname='LAZYLAB_PT_main';bl_space_type='VIEW_3D';bl_region_type='UI';bl_category='Rack Lab';bl_order=-10
    def draw(self,context):
        layout=self.layout;s=state(context);server=selected_server(context)
        if hasattr(context.scene,'rack_question'):
            try:
                bpy.ops.racklab.ask_question.get_rna_type()
                question=layout.box();question.prop(context.scene,'rack_question',text='');question.operator('racklab.ask_question',text='Ask')
            except (RuntimeError,AttributeError):pass
        layout.label(text=server.get('part_id') if server else 'Select a server to inspect it.',icon='OUTLINER_OB_EMPTY')
        grid=layout.grid_flow(row_major=True,columns=2,even_columns=True,align=True)
        for asset,label in [('server.mechanical','Load Inside'),('server.motherboard','Motherboard'),('server.memory','Memory'),('processor.study','Processor Study')]:grid.operator('lazyrack.inspect',text=label).asset_id=asset
        layout.operator('lazyrack.show_rack');layout.operator('lazyrack.unload')
        layout.separator();row=layout.row(align=True);row.prop(s,'rack_target');row.operator('lazyrack.add_rack',text='Add rack')
        layout.prop(s,'add_slot');row=layout.row(align=True);row.operator('lazyrack.add_server');row.operator('lazyrack.remove_server',text='Remove server')
        layout.separator();layout.label(text=f'{s.rack_count} rack(s) · {s.server_count} servers')
        layout.label(text=f'Loaded detail: {s.loaded_assets} assets · {s.mesh_count:,} meshes')
        layout.label(text=f'{s.object_count:,} objects · {s.vertex_count:,} mesh vertices')
        layout.operator('lazyrack.unload_unused')
        import textwrap
        for line in textwrap.wrap(s.status,width=43)[:4]:layout.label(text=line)

CLASSES=(LAZYLAB_Asset,LAZYLAB_Exterior,LAZYLAB_Server,LAZYLAB_Scene,LAZYLAB_State,LAZYLAB_OT_Inspect,LAZYLAB_OT_Back,LAZYLAB_OT_Unload,LAZYLAB_OT_Unused,LAZYLAB_OT_AddServer,LAZYLAB_OT_RemoveServer,LAZYLAB_OT_AddRack,LAZYLAB_PT_Main)
@persistent
def after_file_load(dummy):
    if hasattr(bpy.types.WindowManager,'lazy_lab'):refresh_stats()

def register():
    inspector.register()
    previous=getattr(bpy,'_lazy_lab_classes',())
    if previous and previous!=CLASSES:
        for owner,prop in [(bpy.types.WindowManager,'lazy_lab'),(bpy.types.Scene,'lazy_lab'),(bpy.types.Object,'lazy_lab')]:
            if hasattr(owner,prop):delattr(owner,prop)
        for cls in reversed(previous):
            if cls.is_registered:bpy.utils.unregister_class(cls)
    for cls in CLASSES:
        if not cls.is_registered:bpy.utils.register_class(cls)
    bpy.types.WindowManager.lazy_lab=PointerProperty(type=LAZYLAB_State);bpy.types.Scene.lazy_lab=PointerProperty(type=LAZYLAB_Scene);bpy.types.Object.lazy_lab=PointerProperty(type=LAZYLAB_Server)
    bpy._lazy_lab_classes=CLASSES
    for handler in list(bpy.app.handlers.load_post):
        if getattr(handler,'_lazy_lab_handler',False):bpy.app.handlers.load_post.remove(handler)
    after_file_load._lazy_lab_handler=True;bpy.app.handlers.load_post.append(after_file_load)
    stats=refresh_stats();log('register_no_library_load',stats=stats)

def unregister():
    for handler in list(bpy.app.handlers.load_post):
        if getattr(handler,'_lazy_lab_handler',False):bpy.app.handlers.load_post.remove(handler)
    for owner,prop in [(bpy.types.WindowManager,'lazy_lab'),(bpy.types.Scene,'lazy_lab'),(bpy.types.Object,'lazy_lab')]:
        if hasattr(owner,prop):delattr(owner,prop)
    for cls in reversed(getattr(bpy,'_lazy_lab_classes',CLASSES)):
        if cls.is_registered:bpy.utils.unregister_class(cls)
    if hasattr(bpy,'_lazy_lab_classes'):del bpy._lazy_lab_classes

if __name__=='__main__':register()
