"""Render pregenerated detailed scenes without modifying the saved master."""
import bpy
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
for scene in bpy.data.scenes:
    if scene.name.startswith('01'):continue
    scene.render.engine='BLENDER_WORKBENCH';scene.display.shading.light='STUDIO';scene.display.shading.color_type='MATERIAL';scene.display.shading.show_shadows=True;scene.display.shading.show_cavity=True
    scene.display.shading.cavity_type='WORLD';scene.display.shading.curvature_ridge_factor=1;scene.world.color=(.08,.09,.11)
    scene.render.resolution_x=1600;scene.render.resolution_y=1100;scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG';scene.render.filepath=str(ROOT/'renders'/('detail-'+scene.name[:2]+'.png'))
    bpy.ops.render.render(write_still=True,scene=scene.name)
    print('DETAIL_RENDER_READY',scene.name,scene.render.filepath,flush=True)
