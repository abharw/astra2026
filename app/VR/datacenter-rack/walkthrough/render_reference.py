"""Render a fast viewport-style motion reference from the saved world."""
import bpy, json
from pathlib import Path
root=Path(__file__).resolve().parent
scene=bpy.context.scene
def cube(name,loc,size,material):
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata([(x*size[0]/2,y*size[1]/2,z*size[2]/2) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]],[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)])
    mesh.materials.append(material);o=bpy.data.objects.new(name,mesh);scene.collection.objects.link(o);o.location=loc
    return o
# Graybox motion reference, as in the supplied tutorial. Keep the actual
# evaluated rack footprints and camera motion; use the lit images for detail.
plan=json.loads((root/'floor-plan.json').read_text())
body=bpy.data.materials.new('Blocking rack gray');body.diffuse_color=(.16,.19,.22,1)
front=bpy.data.materials.new('Blocking server silver');front.diffuse_color=(.48,.53,.56,1)
for r in plan['racks']:
    bpy.data.objects[r['id']].hide_render=True
    lo,hi=r['bounds_m']
    cube(r['id']+' blocking',[(a+b)/2 for a,b in zip(lo,hi)],[b-a for a,b in zip(lo,hi)],body)
    import math
    nx,ny=math.sin(r['yaw_rad']),-math.cos(r['yaw_rad'])
    face_x=(hi[0]+.006 if nx>0 else lo[0]-.006) if abs(nx)>.5 else r['position_m'][0]
    face_y=(hi[1]+.006 if ny>0 else lo[1]-.006) if abs(ny)>.5 else r['position_m'][1]
    for i in range(18):
        cube('Blocking server slot',(face_x,face_y,.23+i*.096),(.015,.54,.065) if abs(nx)>.5 else (.54,.015,.065),front)
scene.render.engine='BLENDER_WORKBENCH'
scene.render.resolution_x=1280
scene.render.resolution_y=720
scene.render.resolution_percentage=100
scene.display.shading.light='STUDIO'
scene.display.shading.color_type='MATERIAL'
scene.display.shading.show_shadows=False
scene.display.shading.show_cavity=False
scene.display.shading.cavity_type='BOTH'
scene.display.shading.background_type='WORLD'
scene.display.render_aa='FXAA'
scene.render.image_settings.file_format='PNG'
out=root/'maze-blocking-frames';out.mkdir(exist_ok=True)
scene.render.filepath=str(out/'frame-')
bpy.ops.render.render(animation=True)
