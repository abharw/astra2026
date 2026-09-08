"""Fixed fictional room and regular POV camera; run with Blender -b -P."""
import bpy, math, json, sys, hashlib
from pathlib import Path
from mathutils import Vector

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'renders'; OUT.mkdir(exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene=bpy.context.scene
scene.unit_settings.system='METRIC'

def mat(name,color,metal=0,rough=.45,emission=0):
    m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True
    bs=m.node_tree.nodes.get('Principled BSDF');bs.inputs['Base Color'].default_value=(*color,1)
    bs.inputs['Metallic'].default_value=metal;bs.inputs['Roughness'].default_value=rough
    if emission:bs.inputs['Emission Color'].default_value=(*color,1);bs.inputs['Emission Strength'].default_value=emission
    return m
wall=mat('Warm white painted panels',(.55,.59,.62));floor=mat('Gray raised-floor tiles',(.22,.25,.28),.15,.35)
dark=mat('Dark steel',(.035,.045,.055),.6);blue=mat('Blue cable jacket',(.018,.16,.48),.15)
light=mat('Ceiling light diffuser',(.8,.9,1),0,.3,4);amber=mat('Amber bay identifier',(.9,.38,.035),.2)

def box(name,loc,size,material):
    bpy.ops.mesh.primitive_cube_add(size=1,location=loc);o=bpy.context.object;o.name=name
    o.dimensions=size;bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    o.data.materials.append(material);return o
def label(text,loc,rot,size=.13,material=dark):
    c=bpy.data.curves.new(text,'FONT');c.body=text;c.size=size;c.align_x='CENTER';c.extrude=.001
    o=bpy.data.objects.new('Sign '+text,c);scene.collection.objects.link(o);o.location=loc;o.rotation_euler=rot;c.materials.append(material)
    return o

# Room authority: 8 x 10 x 3.4 m, central south entrance, north service door.
box('Floor slab',(0,0,-.08),(8,10,.16),floor)
for x in range(-6,7):box('Floor joint X',(x*.6,0,.001),(.007,10,.002),dark)
for y in range(-8,9):box('Floor joint Y',(0,y*.6,.002),(8,.007,.002),dark)
for x in [-4,4]:box('Side wall',(x,0,1.7),(.16,10,3.4),wall)
for y in [-5,5]:
    for x in [-2.55,2.55]:box('End wall with door opening',(x,y,1.7),(2.9,.16,3.4),wall)
    box('Door lintel',(0,y,2.95),(2.2,.16,.9),wall)
    for x in [-1.1,1.1]:box('Door jamb',(x,y,1.25),(.09,.22,2.5),dark)
box('North closed service door',(0,4.99,1.25),(2.1,.06,2.5),dark)
box('North amber door panel',(.55,4.94,1.6),(.3,.02,.48),amber)
label('SERVICE 02',(0,4.92,2.67),(math.pi/2,0,0),.17)
label('ENTRY 01',(0,-4.89,2.67),(math.pi/2,0,math.pi),.17)
box('Ceiling',(0,0,3.47),(8,10,.14),wall)
# A real vestibule exists behind the entrance, including its visible rear wall.
box('Vestibule floor',(0,-6.5,-.08),(3,3,.16),floor)
box('Vestibule ceiling',(0,-6.5,3.07),(3,3,.14),wall)
for x in [-1.5,1.5]:box('Vestibule side',(x,-6.5,1.5),(.16,3,3),wall)
box('Vestibule rear wall',(0,-8,1.5),(3,.16,3),wall)
box('Vestibule blue identity panel',(0,-7.9,1.6),(.7,.04,.8),blue)

# Append real saved exterior as a reusable collection. Never load internal detail.
source=ROOT.parent/'models/lazy/rack-exterior.blend'
with bpy.data.libraries.load(str(source),link=False) as (src,dst):dst.collections=['RACK · exterior template']
rack=dst.collections[0]
# Two supplied PSU meshes have a doubled vertical shelf offset. Correct only
# this appended walkthrough copy; retain the source library unchanged.
repairs=[]
for o in rack.all_objects:
    if o.type=='MESH' and o.name.startswith('rack01.psu.') and min(v.co.z for v in o.data.vertices)>3:
        o.data=o.data.copy()
        for v in o.data.vertices:v.co.z-=1.908
        repairs.append({'object':o.name,'delta_z_m':-1.908,'reason':'Remove doubled 1.908 m shelf offset in imported mesh vertices'})
racks=[]
for side,x,angle in [('A',-1.55,math.pi/2),('B',1.55,-math.pi/2)]:
    for i in range(7):
        y=-2.25+i*.75
        o=bpy.data.objects.new(f'Bay {side}{i+1:02}',None);scene.collection.objects.link(o)
        o.instance_type='COLLECTION';o.instance_collection=rack;o.location=(x,y,0);o.rotation_euler.z=angle
        o['evidence']='Authored placement of source-based rack exterior'
        racks.append({'id':o.name,'position_m':list(o.location),'yaw_rad':angle})
        # Fixed numbered signage, attached to world rather than generated frame text.
        rot=(math.pi/2,0,angle)
        sx=x+(.52 if side=='A' else -.52)
        label(f'{side}{i+1:02}',(sx,y,2.18),rot,.11)
    # Physically supported overhead tray and blue cable runs.
    for sx in [x-.22,x+.22]:box('Tray rail',(sx,0,2.75),(.035,6.4,.09),dark)
    for i in range(25):box('Tray rung',(x,-3+i*.25,2.72),(.46,.025,.025),dark)
    for i in range(5):box('Blue cable run',(x-.16+i*.075,0,2.79),(.025,6.3,.025),blue)
    for y in [-2.6,0,2.6]:box('Tray suspension',(x,y,3.08),(.018,.018,.65),dark)

for x in [-2.8,0,2.8]:
    for y in [-3.8,-1.3,1.3,3.8]:
        box('Linear ceiling luminaire',(x,y,3.36),(.18,1.4,.045),light)
        d=bpy.data.lights.new('Practical ceiling area','AREA');d.energy=100;d.shape='RECTANGLE';d.size=.5;d.size_y=1.5
        o=bpy.data.objects.new(d.name,d);scene.collection.objects.link(o);o.location=(x,y,3.28)

world=bpy.data.worlds.new('Interior ambient');world.use_nodes=True;world.node_tree.nodes['Background'].inputs[0].default_value=(.2,.25,.3,1);world.node_tree.nodes['Background'].inputs[1].default_value=.3;scene.world=world
camdata=bpy.data.cameras.new('POV 26mm fixed rectilinear');camdata.lens=26;camdata.sensor_width=36;camdata.clip_start=.04
camera=bpy.data.objects.new('POV camera',camdata);scene.collection.objects.link(camera);scene.camera=camera
camera.rotation_mode='XYZ'
fps=24;scene.render.fps=fps;scene.frame_start=1;scene.frame_end=360
poses=[]
def smooth(t):return t*t*t*(t*(t*6-15)+10)
for f in range(1,361):
    t=(f-1)/24
    p=min(1,t/4);y=-3.8+2.2*smooth(p)
    phase=min(1,max(0,(t-4)/10));yaw=-2*math.pi*smooth(phase)
    bob=.006*math.sin(t*2*math.pi*1.4)*math.sin(math.pi*p)**2 if t<4 else 0
    camera.location=(.008*math.sin(t*2*math.pi*.7)*math.sin(math.pi*p)**2,y,1.65+bob)
    camera.rotation_euler=(math.pi/2,0,yaw)
    camera.keyframe_insert('location',frame=f);camera.keyframe_insert('rotation_euler',frame=f)
    poses.append({'frame':f,'time_s':t,'position_m':list(camera.location),'yaw_rad':yaw})
scene.render.engine='BLENDER_EEVEE'
scene.eevee.shadow_pool_size='1024'
scene.eevee.taa_render_samples=32
scene.render.resolution_x=1280;scene.render.resolution_y=720;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.filepath=str(OUT/'frame-')
scene.view_settings.view_transform='AgX'
scene['scope']='Regular 15-second POV video. Authored fictional room; source-based racks.'
scene['camera_contract']='0–4 s: 2.2 m walk; 4–14 s: stationary full turn; 14–15 s: hold. No cuts or focal-length changes.'
plan={'schema':'datacenter-fixed-world/v1','room_m':[8,10,3.4],'racks':racks,'local_import_repairs':repairs,'camera':{'height_m':1.65,'lens_mm':26,'fps':24,'frames':360,'poses':poses},'source_rack_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'evidence':'Fictional room layout; source-based rack model, not measured real facility'}
bpy.context.view_layer.update()
dg=bpy.context.evaluated_depsgraph_get()
for r in racks:
    pts=[inst.matrix_world@Vector(p) for inst in dg.object_instances if inst.is_instance and inst.parent and inst.parent.name==r['id'] and inst.object.type=='MESH' for p in inst.object.bound_box]
    if pts:r['bounds_m']=[[min(p[a] for p in pts) for a in range(3)],[max(p[a] for p in pts) for a in range(3)]]
(ROOT/'floor-plan.json').write_text(json.dumps(plan,indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'datacenter-world.blend'),compress=True)
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
if 'render' in args:bpy.ops.render.render(animation=True)
else:
    for f in [1,97,157,217,277,337]:
        scene.frame_set(f);scene.render.filepath=str(OUT/f'preview-{f:04}.png');bpy.ops.render.render(write_still=True)
