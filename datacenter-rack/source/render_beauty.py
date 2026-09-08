"""Render the saved exterior with its authored studio lights."""
import bpy
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
s=bpy.context.scene;s.render.engine='CYCLES';s.cycles.device='CPU';s.cycles.samples=32;s.cycles.use_denoising=True
s.render.resolution_x=1200;s.render.resolution_y=1600;s.render.resolution_percentage=100
s.render.image_settings.file_format='PNG';s.render.filepath=str(ROOT/'renders/default-exterior-beauty.png')
s.world.color=(.12,.12,.12)
bpy.ops.render.render(write_still=True)
print('BEAUTY_READY',s.render.filepath,flush=True)
