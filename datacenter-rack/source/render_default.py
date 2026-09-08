"""Quick actual-geometry preview of the exterior-only default."""
import bpy
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
s=bpy.context.scene;s.render.engine='BLENDER_WORKBENCH'
s.display.shading.light='STUDIO';s.display.shading.color_type='MATERIAL';s.display.shading.show_shadows=True;s.display.shading.show_cavity=True;s.display.shading.cavity_type='BOTH';s.display.shading.show_specular_highlight=True;s.display.shading.background_type='WORLD'
s.world.color=(.065,.075,.09);s.render.resolution_x=1200;s.render.resolution_y=1600;s.render.resolution_percentage=100
s.render.image_settings.file_format='PNG';s.render.image_settings.color_mode='RGBA';s.render.filepath=str(ROOT/'renders/default-exterior-preview.png')
for c in s.collection.children:
    if '/ studio' in c.name:
        for o in c.objects:
            if o.type=='MESH':o.hide_render=True
bpy.ops.render.render(write_still=True)
print('DEFAULT_PREVIEW_READY',s.render.filepath,flush=True)
