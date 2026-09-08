"""Optional direct lit reference: preserve geometry, improve practical light placement."""
import bpy,sys
from pathlib import Path
root=Path(__file__).resolve().parent;scene=bpy.context.scene
lamps=sorted([o for o in scene.objects if o.type=='LIGHT'],key=lambda o:o.name)
for i,o in enumerate(lamps):
 vertical=i//3 in [0,2]
 o.location.x+=.8 if vertical else 0
 o.location.y+=0 if vertical else .8
 o.data.energy=350;o.data.shape='DISK';o.data.size=1.3
scene.render.engine='BLENDER_EEVEE';scene.eevee.taa_render_samples=16
scene.render.image_settings.file_format='PNG'
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
if 'animation' in args:
 out=root/'lit-frames';out.mkdir(exist_ok=True);scene.render.filepath=str(out/'frame-');bpy.ops.render.render(animation=True)
else:
 out=root/'lit-previews';out.mkdir(exist_ok=True)
 for f in [1,193,361,529,719]:
  scene.frame_set(f);scene.render.filepath=str(out/f'frame-{f:04}.png');bpy.ops.render.render(write_still=True)
