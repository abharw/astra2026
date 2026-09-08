"""Export the exterior scene to GLB/USDZ without presentation lights or floor."""
from pathlib import Path
import bpy,json
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'models/lazy'
scene=bpy.context.scene;rack=bpy.data.collections['RACK · exterior template']
for col in list(scene.collection.children):
    if col!=rack:scene.collection.children.unlink(col)
# Bake only curve primitives for interchange; original editable curves stay saved.
dg=bpy.context.evaluated_depsgraph_get()
for obj in list(rack.objects):
    if obj.type not in {'CURVE','FONT'}:continue
    mesh=bpy.data.meshes.new_from_object(obj.evaluated_get(dg),depsgraph=dg)
    replacement=bpy.data.objects.new(obj.name+'.export',mesh);rack.objects.link(replacement);replacement.parent=obj.parent;replacement.matrix_world=obj.matrix_world
    for key in obj.keys():replacement[key]=obj[key]
    bpy.data.objects.remove(obj,do_unlink=True)
gltf=OUT/'rack-exterior.glb'
bpy.ops.export_scene.gltf(filepath=str(gltf),export_format='GLB',use_active_scene=True,export_apply=True,export_animations=False,export_cameras=False,export_lights=False,export_extras=True,export_gpu_instances=False,export_yup=True)
usd=OUT/'rack-exterior.usdz'
bpy.ops.wm.usd_export(filepath=str(usd),selected_objects_only=False,export_animation=False,export_hair=False,export_materials=True,use_instancing=True,generate_preview_surface=True,generate_materialx_network=False,export_lights=False,export_cameras=False,export_custom_properties=True,export_textures_mode='NEW',convert_scene_units='METERS')
manifest=json.loads((OUT/'manifest.json').read_text());manifest['assets']['rack.exterior']={'asset_id':'rack.exterior','collection':rack.name,'library':'rack-exterior.blend','glb':'rack-exterior.glb','usdz':'rack-exterior.usdz','description':'Exterior-only vertical stack; independent selectable server nodes and shared mesh data','initial_load':True}
manifest['interchange_coordinates']={'glb':'Y up, translation [Blender X, Blender Z, -Blender Y]','blend':'Z up; all manifest source placements are Blender meters','usdz':'See stage upAxis metadata; metersPerUnit1'}
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2))
print('RUNTIME_EXPORT_COMPLETE',json.dumps({'glb_bytes':gltf.stat().st_size,'usdz_bytes':usd.stat().st_size}),flush=True)
