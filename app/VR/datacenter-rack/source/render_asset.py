"""Render one already-authored asset view without modifying its source file."""
from pathlib import Path
import sys,argparse
import bpy
from mathutils import Vector
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--view',choices=['rack','server','board','processor','rack-rear','board-macro'],default='server');p.add_argument('--samples',type=int,default=64);p.add_argument('--percent',type=int,default=100);p.add_argument('--cpu',action='store_true');p.add_argument('--output');a=p.parse_args(sys.argv[sys.argv.index('--')+1:])
names={'rack':'01 · Full rack','rack-rear':'01 · Full rack','server':'02 · Open server','board':'03 · Motherboard fabrication','board-macro':'03 · Motherboard fabrication','processor':'04 · Processor study'}
s=bpy.data.scenes[names[a.view]];bpy.context.window.scene=s
if a.view=='rack-rear':
    s.camera.location=(-3.1,4.6,2.8);s.camera.rotation_euler=(Vector((0,.05,1.1))-s.camera.location).to_track_quat('-Z','Y').to_euler()
if a.view=='board-macro':
    s.camera.location=(-.08,-.005,.12);s.camera.rotation_euler=(Vector((-.08,.105,.017))-s.camera.location).to_track_quat('-Z','Y').to_euler();s.camera.data.ortho_scale=.19;s.render.resolution_x=1900;s.render.resolution_y=1500
s.cycles.samples=a.samples;s.render.resolution_percentage=a.percent
if a.cpu:s.cycles.device='CPU'
else:
    prefs=bpy.context.preferences.addons['cycles'].preferences;prefs.compute_device_type='METAL';prefs.get_devices()
    for d in prefs.devices:d.use=d.type=='METAL'
    s.cycles.device='GPU'
s.render.filepath=a.output or str(ROOT/f'renders/{a.view}.png')
print('RENDER_START',a.view,s.cycles.device,s.render.filepath,flush=True)
bpy.ops.render.render(write_still=True,scene=s.name)
print('RENDER_COMPLETE',a.view,flush=True)
