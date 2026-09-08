"""Rack Lab: session-loaded Blender inspector. No network access or scene authoring on load."""
bl_info = {'name': 'Rack Lab', 'author': 'Rack reconstruction project', 'version': (1, 0, 0), 'blender': (4, 2, 0), 'location': 'View3D > Sidebar > Rack Lab', 'category': '3D View'}
import bpy
import math
from mathutils import Matrix, Vector
from bpy.props import StringProperty, BoolProperty, FloatProperty, FloatVectorProperty, IntProperty, PointerProperty, CollectionProperty

SEARCH_FIELDS = ('part_id', 'cad_name', 'refdes', 'MPN', 'mpn', 'manufacturer_part_number', 'manufacturer', 'function', 'description')
SCENE_LINKS=(('01 · Full rack','Rack'),('02 · Open server','Open server'),('03 · Motherboard fabrication','Motherboard'),('04 · Processor study','Processor'))

def inspectable_part(obj):
    if not obj.get('part_id') or obj.type in {'CAMERA','LIGHT'}:return False
    if obj.get('presentation_only') or obj.get('role')=='studio':return False
    return not any(c.name.casefold().endswith('/ studio') for c in obj.users_collection)

def instance_bounds(obj):
    """World AABB from collection members, offsets and nested instance transforms."""
    if obj.instance_type!='COLLECTION' or not obj.instance_collection:return None
    low=Vector((math.inf,)*3);high=Vector((-math.inf,)*3);found=False
    stack=[(obj.instance_collection,obj.matrix_world.copy(),())]
    while stack:
        collection,transform,ancestors=stack.pop()
        if collection.as_pointer() in ancestors:continue
        transform=transform@Matrix.Translation(-collection.instance_offset)
        ancestors=ancestors+(collection.as_pointer(),)
        for member in collection.all_objects:
            if member.hide_viewport:continue
            world=transform@member.matrix_world
            if member.instance_type=='COLLECTION' and member.instance_collection:
                stack.append((member.instance_collection,world,ancestors))
            if member.type not in {'MESH','CURVE','SURFACE','FONT','META','VOLUME'}:continue
            for corner in member.bound_box:
                point=world@Vector(corner);found=True
                for axis in range(3):low[axis]=min(low[axis],point[axis]);high[axis]=max(high[axis],point[axis])
    return (low,high) if found else None

def open_inspection_scene(context,target):
    context.window.scene=target
    if target.camera:
        for area in context.window.screen.areas:
            if area.type!='VIEW_3D':continue
            space=area.spaces.active;space.camera=target.camera
            regions=list(space.region_quadviews) if space.region_quadviews else [space.region_3d]
            for region in regions:
                if region:
                    region.view_perspective='CAMERA';region.view_camera_zoom=0;region.view_camera_offset=(0,0)
            area.tag_redraw()
    # Overlays, selection restrictions and authored camera transforms stay intact.

class RACKLAB_OT_Scene(bpy.types.Operator):
    bl_idname='racklab.open_scene';bl_label='Open inspection scene';bl_description='Open an existing rack inspection scene'
    scene_name: StringProperty()
    @classmethod
    def poll(cls,context):return context.window is not None and context.mode=='OBJECT'
    def execute(self,context):
        target=bpy.data.scenes.get(self.scene_name)
        if target is None:self.report({'WARNING'},'This inspection scene is not available.');return {'CANCELLED'}
        open_inspection_scene(context,target)
        return {'FINISHED'}

class RACKLAB_OT_InspectServer(bpy.types.Operator):
    bl_idname='racklab.inspect_server';bl_label='Inspect Server';bl_description='Open the selected server instance in its editable service scene'
    @classmethod
    def poll(cls,context):return context.window is not None and context.mode=='OBJECT' and context.active_object is not None and bool(context.active_object.get('service_scene'))
    def execute(self,context):
        name=str(context.active_object.get('service_scene',''));target=bpy.data.scenes.get(name)
        if target is None:self.report({'WARNING'},'The service scene recorded on this instance is missing.');return {'CANCELLED'}
        open_inspection_scene(context,target)
        return {'FINISHED'}

def descendants(root):
    child_map={}
    for obj in bpy.data.objects:
        if obj.parent:child_map.setdefault(obj.parent,[]).append(obj)
    result=[];stack=[root]
    while stack:
        obj=stack.pop();result.append(obj);stack.extend(child_map.get(obj,()))
    return result

def assembly_for(obj):
    current=obj
    while current:
        if bool(current.get('assembly', False)) or current.name.endswith('.assembly') or (current.type == 'EMPTY' and current.children):
            return current
        current=current.parent
    return obj

def flat(matrix):
    return [v for row in matrix for v in row]

def matrix(values):
    return Matrix([values[i:i+4] for i in range(0,16,4)])

def choose(context, obj):
    if obj is None or obj.name not in context.view_layer.objects:
        return False, 'This object is not in the current view layer.'
    if obj.hide_viewport or not obj.visible_get(view_layer=context.view_layer):
        return False, 'This object is hidden. Restore isolation or reveal its collection first.'
    if obj.hide_select:
        return False, 'This object has selection disabled in the Outliner.'
    if context.mode != 'OBJECT':
        return False, 'Return to Object Mode first.'
    for selected in context.selected_objects: selected.select_set(False)
    obj.select_set(True);context.view_layer.objects.active=obj
    return True, ''

class RACKLAB_Result(bpy.types.PropertyGroup):
    obj: PointerProperty(type=bpy.types.Object)

class RACKLAB_Transform(bpy.types.PropertyGroup):
    obj: PointerProperty(type=bpy.types.Object)
    original_parent: PointerProperty(type=bpy.types.Object)
    original_parent_type: StringProperty()
    original_parent_bone: StringProperty()
    world: FloatVectorProperty(size=16)
    basis: FloatVectorProperty(size=16)
    parent_inverse: FloatVectorProperty(size=16)
    depth: IntProperty()

class RACKLAB_Hidden(bpy.types.PropertyGroup):
    obj: PointerProperty(type=bpy.types.Object)
    hidden: BoolProperty()

class RACKLAB_State(bpy.types.PropertyGroup):
    query: StringProperty(name='Find a part', description='Search names, part IDs, CAD names, reference designators, MPNs and metadata')
    results: CollectionProperty(type=RACKLAB_Result)
    result_index: IntProperty()
    total_matches: IntProperty()
    searched: BoolProperty()
    distance: FloatProperty(name='Separation', default=.12, min=.001, max=5, subtype='DISTANCE', unit='LENGTH')
    transforms: CollectionProperty(type=RACKLAB_Transform)
    hidden: CollectionProperty(type=RACKLAB_Hidden)
    isolate_layer: StringProperty()
    isolate_active: BoolProperty()

class RACKLAB_OT_Search(bpy.types.Operator):
    bl_idname='racklab.search';bl_label='Search';bl_description='Search scene metadata when clicked; show up to 100 matches'
    def execute(self,context):
        state=context.scene.rack_lab;tokens=state.query.casefold().split()
        state.results.clear();state.total_matches=0;state.result_index=0;state.searched=True
        if not tokens:
            self.report({'INFO'},'Enter a part name, reference designator or part number.');return {'CANCELLED'}
        for obj in context.scene.objects:
            if not inspectable_part(obj):continue
            haystack=' '.join([obj.name]+[str(obj.get(k,''))[:8000] for k in SEARCH_FIELDS]).casefold()
            if all(token in haystack for token in tokens):
                state.total_matches+=1
                if len(state.results)<100:state.results.add().obj=obj
        return {'FINISHED'}

class RACKLAB_OT_SelectResult(bpy.types.Operator):
    bl_idname='racklab.select_result';bl_label='Select result';bl_options={'REGISTER','UNDO'}
    def execute(self,context):
        state=context.scene.rack_lab
        if not state.results or not 0<=state.result_index<len(state.results):return {'CANCELLED'}
        ok,message=choose(context,state.results[state.result_index].obj)
        if not ok:self.report({'WARNING'},message);return {'CANCELLED'}
        return {'FINISHED'}

class RACKLAB_OT_Frame(bpy.types.Operator):
    bl_idname='racklab.frame';bl_label='Frame selected'
    @classmethod
    def poll(cls,context):return context.active_object is not None and context.area is not None and context.area.type=='VIEW_3D'
    def execute(self,context):
        region=next((r for r in context.area.regions if r.type=='WINDOW'),None)
        if not region:return {'CANCELLED'}
        previous=list(context.selected_objects);active=context.view_layer.objects.active
        temporary=None;temporary_mesh=None
        try:
            if context.mode=='OBJECT':
                framed=set()
                for obj in previous:framed.update(descendants(obj))
                bounds=[]
                for obj in framed:
                    if obj.name in context.view_layer.objects and obj.visible_get(view_layer=context.view_layer) and not obj.hide_select:
                        obj.select_set(True)
                        result=instance_bounds(obj)
                        if result:bounds.append(result)
                if bounds:
                    vertices=[]
                    for low,high in bounds:
                        vertices.extend((x,y,z) for x in [low.x,high.x] for y in [low.y,high.y] for z in [low.z,high.z])
                    temporary_mesh=bpy.data.meshes.new('Rack Lab temporary instance bounds');temporary_mesh.from_pydata(vertices,[],[]);temporary_mesh.update()
                    temporary=bpy.data.objects.new('Rack Lab temporary instance bounds',temporary_mesh);context.scene.collection.objects.link(temporary);temporary.hide_render=True
                    if context.space_data.local_view:temporary.local_view_set(context.space_data,True)
                    temporary.select_set(True);context.view_layer.update()
            with context.temp_override(region=region):bpy.ops.view3d.view_selected(use_all_regions=False)
        finally:
            if temporary:bpy.data.objects.remove(temporary,do_unlink=True)
            if temporary_mesh:bpy.data.meshes.remove(temporary_mesh)
            if context.mode=='OBJECT':
                for obj in context.selected_objects:obj.select_set(False)
                for obj in previous:obj.select_set(True)
                context.view_layer.objects.active=active
        return {'FINISHED'}

class RACKLAB_OT_Assembly(bpy.types.Operator):
    bl_idname='racklab.select_assembly';bl_label='Select owning assembly';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return context.active_object is not None and context.mode=='OBJECT'
    def execute(self,context):
        ok,message=choose(context,assembly_for(context.active_object))
        if not ok:self.report({'WARNING'},message);return {'CANCELLED'}
        return {'FINISHED'}

class RACKLAB_OT_Isolate(bpy.types.Operator):
    bl_idname='racklab.isolate';bl_label='Isolate assembly';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return context.active_object is not None and context.mode=='OBJECT'
    def execute(self,context):
        state=context.scene.rack_lab;layer=context.view_layer
        if state.isolate_active and state.isolate_layer!=layer.name:
            self.report({'WARNING'},'Restore the previous isolation before switching view layers.');return {'CANCELLED'}
        if not state.isolate_active:
            state.hidden.clear()
            for obj in layer.objects:
                row=state.hidden.add();row.obj=obj;row.hidden=obj.hide_get(view_layer=layer)
            state.isolate_layer=layer.name;state.isolate_active=True
        keep=set(descendants(assembly_for(context.active_object)))
        current=context.active_object.parent
        while current:keep.add(current);current=current.parent
        original={row.obj:row.hidden for row in state.hidden if row.obj}
        # Never reveal something the human had hidden before isolation.
        for obj in layer.objects:obj.hide_set(original.get(obj,obj.hide_get(view_layer=layer)) or obj not in keep,view_layer=layer)
        return {'FINISHED'}

class RACKLAB_OT_ShowAll(bpy.types.Operator):
    bl_idname='racklab.show_all';bl_label='Show all (restore visibility)';bl_description='Restore visibility from before Rack Lab isolation; preserve prior human-hidden objects';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return context.scene.rack_lab.isolate_active
    def execute(self,context):
        state=context.scene.rack_lab;layer=context.scene.view_layers.get(state.isolate_layer)
        if layer is None:
            self.report({'ERROR'},'Original view layer is missing; restoration state was retained.');return {'CANCELLED'}
        for row in state.hidden:
            if row.obj and row.obj.name in layer.objects:row.obj.hide_set(row.hidden,view_layer=layer)
        state.hidden.clear();state.isolate_active=False;state.isolate_layer=''
        return {'FINISHED'}

class RACKLAB_OT_Explode(bpy.types.Operator):
    bl_idname='racklab.explode';bl_label='Explode one level';bl_description='Separate direct children of the selected assembly; store full transforms until restored';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return context.active_object is not None and context.mode=='OBJECT' and not context.scene.rack_lab.transforms
    def execute(self,context):
        state=context.scene.rack_lab;root=assembly_for(context.active_object)
        children=list(root.children)
        if not children:
            self.report({'INFO'},'Select an assembly with child parts.');return {'CANCELLED'}
        affected=descendants(root)
        if any(o.constraints or o.animation_data for o in affected):
            self.report({'WARNING'},'This assembly has animation or constraints. Explode a static assembly instead.');return {'CANCELLED'}
        for obj in affected:
            row=state.transforms.add();row.obj=obj;row.original_parent=obj.parent;row.original_parent_type=obj.parent_type;row.original_parent_bone=obj.parent_bone
            row.world=flat(obj.matrix_world);row.basis=flat(obj.matrix_basis);row.parent_inverse=flat(obj.matrix_parent_inverse)
            parent=obj.parent;depth=0
            while parent:depth+=1;parent=parent.parent
            row.depth=depth
        for i,obj in enumerate(children):
            # Radial presentation separation, not a mechanical removal procedure.
            angle=2*math.pi*i/len(children)
            direction=Vector((math.cos(angle),math.sin(angle),.35 if i%2 else -.35)).normalized()
            transform=obj.matrix_world.copy();transform.translation+=direction*state.distance;obj.matrix_world=transform
        context.view_layer.update()
        return {'FINISHED'}

class RACKLAB_OT_Restore(bpy.types.Operator):
    bl_idname='racklab.restore';bl_label='Restore original transforms';bl_description='Restore saved world transforms and original parent relationships, including after reopening this file';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return bool(context.scene.rack_lab.transforms) and context.mode=='OBJECT'
    def execute(self,context):
        state=context.scene.rack_lab;rows=sorted(list(state.transforms),key=lambda row:row.depth)
        missing=sum(row.obj is None for row in rows)
        for row in rows:
            obj=row.obj
            if not obj:continue
            obj.parent=row.original_parent;obj.parent_type=row.original_parent_type;obj.parent_bone=row.original_parent_bone
            obj.matrix_parent_inverse=matrix(row.parent_inverse);obj.matrix_basis=matrix(row.basis)
        context.view_layer.update()
        # Parent-first world assignment also recovers manual changes made during inspection.
        from itertools import groupby
        for depth,group in groupby(rows,key=lambda row:row.depth):
            for row in group:
                if row.obj:row.obj.matrix_world=matrix(row.world)
            context.view_layer.update()
        state.transforms.clear()
        if missing:self.report({'WARNING'},f'Restored surviving objects; {missing} deleted objects cannot be recovered.')
        return {'FINISHED'}

class RACKLAB_OT_EditCurve(bpy.types.Operator):
    bl_idname='racklab.edit_curve';bl_label='Edit cable route points';bl_options={'REGISTER','UNDO'}
    @classmethod
    def poll(cls,context):return context.active_object is not None and context.active_object.type=='CURVE' and context.mode=='OBJECT'
    def execute(self,context):
        obj=context.active_object
        if obj.library or obj.data.library:
            self.report({'WARNING'},'This curve is linked and read-only.');return {'CANCELLED'}
        ok,message=choose(context,obj)
        if not ok:self.report({'WARNING'},message);return {'CANCELLED'}
        bpy.ops.object.mode_set(mode='EDIT')
        return {'FINISHED'}

class RACKLAB_UL_Results(bpy.types.UIList):
    def draw_item(self,context,layout,data,item,icon,active_data,active_propname,index):
        obj=item.obj
        layout.label(text=obj.name if obj else '(deleted object)',icon='OBJECT_DATA' if obj else 'ERROR')

def wrapped(layout,label,value):
    value=str(value or '').strip()
    if not value:return
    col=layout.column(align=True);col.label(text=label+':')
    # Bound drawing cost and text length. Full value is also in Custom Properties.
    import textwrap
    lines=textwrap.wrap(value[:1200],width=42,break_long_words=True) or ['']
    for line in lines[:14]:col.label(text=line)
    if len(lines)>14:col.label(text='… see Object > Custom Properties')

class RACKLAB_PT_Main(bpy.types.Panel):
    bl_label='Rack Lab';bl_idname='RACKLAB_PT_main';bl_space_type='VIEW_3D';bl_region_type='UI';bl_category='Rack Lab'
    def draw(self,context):
        layout=self.layout;state=context.scene.rack_lab;obj=context.active_object
        grid=layout.grid_flow(row_major=True,columns=2,even_columns=True,align=True)
        for scene_name,label in SCENE_LINKS:
            if bpy.data.scenes.get(scene_name):
                button=grid.operator('racklab.open_scene',text=label,depress=context.scene.name==scene_name);button.scene_name=scene_name
        if obj and obj.get('service_scene'):layout.operator('racklab.inspect_server',icon='VIEWZOOM')
        layout.separator()
        row=layout.row(align=True);row.prop(state,'query',text='');row.operator('racklab.search',text='',icon='VIEWZOOM')
        if state.searched:
            layout.label(text=f'{state.total_matches} matches'+(' (first 100)' if state.total_matches>100 else ''))
            if state.results:
                layout.template_list('RACKLAB_UL_Results','',state,'results',state,'result_index',rows=4)
                layout.operator('racklab.select_result')
        layout.separator();layout.operator('racklab.frame');layout.operator('racklab.select_assembly')
        row=layout.row(align=True);row.operator('racklab.isolate',text='Isolate');row.operator('racklab.show_all',text='Show all')
        layout.prop(state,'distance');layout.operator('racklab.explode');layout.operator('racklab.restore')
        if state.transforms:layout.label(text='Save file to keep restoration state.',icon='INFO')
        if obj and obj.type=='CURVE':layout.operator('racklab.edit_curve')
        layout.label(text='Move: G · Rotate: R · Scale: S')
        layout.label(text='Curve points: Tab to finish editing')
        if obj:
            box=layout.box();box.label(text=obj.name,icon='OBJECT_DATA')
            for key,label in [('part_id','Part'),('cad_name','CAD name'),('refdes','Reference'),('MPN','Part number'),('mpn','Part number'),('manufacturer_part_number','Part number'),('manufacturer','Manufacturer'),('function','Function'),('description','Description'),('evidence_level','Evidence'),('source_url','Source')]:wrapped(box,label,obj.get(key))
        else:layout.label(text='Select a part to inspect its metadata.')

CLASSES=(RACKLAB_Result,RACKLAB_Transform,RACKLAB_Hidden,RACKLAB_State,RACKLAB_OT_Scene,RACKLAB_OT_InspectServer,RACKLAB_OT_Search,RACKLAB_OT_SelectResult,RACKLAB_OT_Frame,RACKLAB_OT_Assembly,RACKLAB_OT_Isolate,RACKLAB_OT_ShowAll,RACKLAB_OT_Explode,RACKLAB_OT_Restore,RACKLAB_OT_EditCurve,RACKLAB_UL_Results,RACKLAB_PT_Main)
def register():
    previous=getattr(bpy,'_rack_lab_registered_classes',())
    if previous and previous!=CLASSES:
        if hasattr(bpy.types.Scene,'rack_lab'):del bpy.types.Scene.rack_lab
        for cls in reversed(previous):
            if cls.is_registered:bpy.utils.unregister_class(cls)
    for cls in CLASSES:
        if not cls.is_registered:bpy.utils.register_class(cls)
    if not hasattr(bpy.types.Scene,'rack_lab'):bpy.types.Scene.rack_lab=PointerProperty(type=RACKLAB_State)
    bpy._rack_lab_registered_classes=CLASSES

def unregister():
    if hasattr(bpy.types.Scene,'rack_lab'):del bpy.types.Scene.rack_lab
    for cls in reversed(getattr(bpy,'_rack_lab_registered_classes',CLASSES)):
        if cls.is_registered:bpy.utils.unregister_class(cls)
    if hasattr(bpy,'_rack_lab_registered_classes'):del bpy._rack_lab_registered_classes

if __name__=='__main__':register()
