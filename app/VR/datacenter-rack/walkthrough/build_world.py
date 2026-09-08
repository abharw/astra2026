"""Build the authored maze benchmark and its conventional 30-second POV shot."""
import bpy, math, json, sys, hashlib
from pathlib import Path
from mathutils import Vector
ROOT=Path(__file__).resolve().parent
OUT=ROOT/'maze-previews';OUT.mkdir(exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene=bpy.context.scene;scene.unit_settings.system='METRIC'
def mat(name,color,metal=0,rough=.45,emission=0):
 m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True;b=m.node_tree.nodes.get('Principled BSDF');b.inputs['Base Color'].default_value=(*color,1);b.inputs['Metallic'].default_value=metal;b.inputs['Roughness'].default_value=rough
 if emission:b.inputs['Emission Color'].default_value=(*color,1);b.inputs['Emission Strength'].default_value=emission
 return m
wall=mat('Off-white wall',(.58,.6,.61));floor=mat('Gray raised floor',(.25,.27,.29),.12,.4);dark=mat('Dark steel',(.035,.045,.055),.5);blue=mat('Blue cable jacket',(.015,.12,.36),.1)
silver=mat('Aluminum tray',(.34,.38,.41),.65);light=mat('Ceiling diffuser',(.85,.92,1),0,.3,3)
colors=[mat('Amber junction',(.9,.36,.025)),mat('Cyan junction',(.03,.5,.62)),mat('Red junction',(.7,.04,.045)),mat('Green destination',(.045,.42,.22))]
def box(name,loc,size,m):
 mesh=bpy.data.meshes.new(name);mesh.from_pydata([(x*size[0]/2,y*size[1]/2,z*size[2]/2) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]],[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]);mesh.materials.append(m);o=bpy.data.objects.new(name,mesh);scene.collection.objects.link(o);o.location=loc;return o
def text(body,loc,rot,size=.16,m=None):
 c=bpy.data.curves.new(body,'FONT');c.body=body;c.size=size;c.align_x='CENTER';c.extrude=.001;o=bpy.data.objects.new('Sign '+body,c);scene.collection.objects.link(o);o.location=loc;o.rotation_euler=rot;c.materials.append(m or dark);return o
# Four unions of axis-aligned gallery rectangles; north is +Y only as an authored convention.
rects=[{'id':'A','bounds':[1.5,-8.5,6.5,2.5]},{'id':'B','bounds':[-4.5,-2.5,6.5,2.5]},{'id':'C','bounds':[-4.5,-2.5,.5,8.5]},{'id':'D','bounds':[-10.5,3.5,.5,8.5]},{'id':'entry','bounds':[3,-10.5,5,-8.5]}]
step=.5;cells=set()
for r in rects:
 x0,y0,x1,y1=r['bounds']
 for i in range(round(x0/step),round(x1/step)):
  for j in range(round(y0/step),round(y1/step)):cells.add((i,j))
for i,j in cells:
 x=(i+.5)*step;y=(j+.5)*step
 box('Floor tile',(x,y,-.045),(.496,.496,.09),floor)
 box('Ceiling tile',(x,y,3.45),(.5,.5,.1),wall)
wall_bounds=[]
for i,j in cells:
 for di,dj in [(1,0),(-1,0),(0,1),(0,-1)]:
  if (i+di,j+dj) in cells:continue
  x=(i+.5+di*.5)*step;y=(j+.5+dj*.5)*step
  size=(.14,.5,3.4) if di else (.5,.14,3.4)
  box('Gallery wall',(x,y,1.7),size,wall)
  wall_bounds.append([[x-size[0]/2,y-size[1]/2,0],[x+size[0]/2,y+size[1]/2,3.4]])
# Distinct permanent anchors. They remain visible only when physically in view.
box('J1 amber identification panel',(4,2.405,1.5),(1.1,.05,1.15),colors[0]);text('BAY 01',(4,2.365,2.23),(math.pi/2,0,0),.2)
box('J2 cyan identification panel',(-4.405,0,1.5),(.05,1.1,1.15),colors[1]);text('BAY 02',(-4.365,0,2.23),(math.pi/2,0,math.pi/2),.2)
box('J3 red identification panel',(-2,8.405,1.5),(1.1,.05,1.15),colors[2]);text('BAY 03',(-2,8.365,2.23),(math.pi/2,0,0),.2)
box('Destination green service door',(-10.405,6,1.2),(.05,1.9,2.4),colors[3]);text('SERVICE 04',(-10.365,6,2.65),(math.pi/2,0,math.pi/2),.18)
box('Entry blue panel',(4,-10.405,1.5),(.8,.05,.8),blue);text('ENTRY',(4,-10.365,2.2),(math.pi/2,0,math.pi),.2)
source=ROOT.parent/'models/lazy/rack-exterior.blend'
with bpy.data.libraries.load(str(source),link=False) as (s,d):d.collections=['RACK · exterior template']
rack=d.collections[0];repairs=[]
for o in rack.all_objects:
 if o.type=='MESH' and o.name.startswith('rack01.psu.') and min(v.co.z for v in o.data.vertices)>3:
  o.data=o.data.copy()
  for v in o.data.vertices:v.co.z-=1.908
  repairs.append({'object':o.name,'delta_z_m':-1.908,'reason':'Doubled shelf offset in source mesh'})
racks=[]
def add_rack(section,x,y,angle):
 name=f'{section}{1+sum(r["section"]==section for r in racks):02}'
 o=bpy.data.objects.new('Bay '+name,None);scene.collection.objects.link(o);o.instance_type='COLLECTION';o.instance_collection=rack;o.location=(x,y,0);o.rotation_euler.z=angle
 racks.append({'id':o.name,'section':section,'position_m':[x,y,0],'yaw_rad':angle})
 # Sign faces the aisle, with placement relative to the same original front plane.
 nx,ny=math.sin(angle),-math.cos(angle)
 text(name,(x+.56*nx,y+.56*ny,2.23),(math.pi/2,0,angle),.12)
# Rack banks stop before intersections, leaving the turns physically open.
for y in [-6.5,-5.75,-5,-4.25,-3.5]:
 add_rack('A',2.15,y,math.pi/2);add_rack('A',5.85,y,-math.pi/2)
for x in [.6,1.35]:
 add_rack('B',x,-1.85,math.pi);add_rack('B',x,1.85,0)
for y in [2.8,3.55]:
 add_rack('C',-3.85,y,math.pi/2);add_rack('C',-.15,y,-math.pi/2)
for x in [-5,-5.75,-6.5,-7.25,-8,-8.75]:
 add_rack('D',x,4.15,math.pi);add_rack('D',x,7.85,0)
# Cable trays and practical lighting follow each actual gallery, with supported joins.
segments=[((4,-7),(4,0)),((4,0),(-2,0)),((-2,0),(-2,6)),((-2,6),(-9,6))]
for k,(a,b) in enumerate(segments):
 vertical=a[0]==b[0];length=math.dist(a,b);cx=(a[0]+b[0])/2;cy=(a[1]+b[1])/2
 for offset in [-.3,.3]:box('Tray side rail',(cx+(offset if vertical else 0),cy+(0 if vertical else offset),2.9),(.025,length,.08) if vertical else (length,.025,.08),silver)
 for n in range(round(length/.3)+1):
  f=n/max(1,round(length/.3));x=a[0]+f*(b[0]-a[0]);y=a[1]+f*(b[1]-a[1]);box('Tray rung',(x,y,2.87),(.6,.02,.025) if vertical else (.02,.6,.025),silver)
 for offset in [-.18,-.09,0,.09,.18]:box('Blue overhead cable',(cx+(offset if vertical else 0),cy+(0 if vertical else offset),2.94),(.025,length,.025) if vertical else (length,.025,.025),blue)
 for f in [.15,.5,.85]:
  x=a[0]+f*(b[0]-a[0]);y=a[1]+f*(b[1]-a[1]);box('Tray support',(x,y,3.17),(.018,.018,.5),dark)
  box('Linear ceiling light',(x+(.8 if vertical else 0),y+(0 if vertical else .8),3.36),(.18,1.3,.035) if vertical else (1.3,.18,.035),light)
  ld=bpy.data.lights.new('Ceiling practical','AREA');ld.energy=180;ld.shape='DISK';ld.size=2
  lo=bpy.data.objects.new(ld.name,ld);scene.collection.objects.link(lo);lo.location=(x,y,3.25)
world=bpy.data.worlds.new('Room ambient');world.use_nodes=True;world.node_tree.nodes['Background'].inputs[0].default_value=(.35,.4,.45,1);world.node_tree.nodes['Background'].inputs[1].default_value=.35;scene.world=world
camera_data=bpy.data.cameras.new('POV fixed 24mm');camera_data.lens=24;camera_data.sensor_width=36;camera_data.clip_start=.04
camera=bpy.data.objects.new('POV camera',camera_data);scene.collection.objects.link(camera);scene.camera=camera;camera.rotation_mode='XYZ'
fps=24;scene.render.fps=fps;scene.frame_start=1;scene.frame_end=720
route=[(4,-6),(4,0),(-2,0),(-2,6),(-8,6)]
# Each straight finishes before the junction pan. No cut, teleport, or hidden doorway.
timeline=[(0,6,0,1,0,0,'walk'),(6,8,1,1,0,90,'left'),(8,13,1,2,90,90,'walk'),(13,15,2,2,90,0,'right'),(15,20,2,3,0,0,'walk'),(20,22,3,3,0,90,'left'),(22,27,3,4,90,90,'walk'),(27,30,4,4,90,-90,'look back')]
def smooth(t):return t*t*t*(t*(t*6-15)+10)
def walk_ease(t):
 # Smooth acceleration over 15% at each end, constant speed in the middle.
 r=.15
 if t<r:return (t/2-r*math.sin(math.pi*t/r)/(2*math.pi))/(1-r)
 if t>1-r:return 1-walk_ease(1-t)
 return (t-r/2)/(1-r)
poses=[]
for f in range(1,721):
 t=(f-1)/fps
 seg=next(s for s in timeline if s[0]<=t<s[1]);start,end,i,j,yaw0,yaw1,action=seg;u=(t-start)/(end-start)
 w=walk_ease(u) if action=='walk' else smooth(u)
 x=route[i][0]+(route[j][0]-route[i][0])*w;y=route[i][1]+(route[j][1]-route[i][1])*w
 yaw=math.radians(yaw0+(yaw1-yaw0)*smooth(u));bob=.007*math.sin(t*2*math.pi*1.5)*math.sin(math.pi*u)**2 if action=='walk' else 0
 camera.location=(x,y,1.65+bob);camera.rotation_euler=(math.pi/2,0,yaw);camera.keyframe_insert('location',frame=f);camera.keyframe_insert('rotation_euler',frame=f)
 poses.append({'frame':f,'time_s':t,'position_m':list(camera.location),'yaw_rad':yaw,'action':action})
scene.render.engine='BLENDER_EEVEE';scene.eevee.shadow_pool_size='1024';scene.eevee.taa_render_samples=32
scene.render.resolution_x=1280;scene.render.resolution_y=720;scene.render.resolution_percentage=100;scene.render.image_settings.file_format='PNG';scene.view_settings.view_transform='AgX'
scene['scope']='30-second regular POV maze benchmark. Straight, left, right, left, then pan back.'
bpy.context.view_layer.update();dg=bpy.context.evaluated_depsgraph_get()
for r in racks:
 pts=[inst.matrix_world@Vector(p) for inst in dg.object_instances if inst.is_instance and inst.parent and inst.parent.name==r['id'] and inst.object.type=='MESH' for p in inst.object.bound_box]
 r['bounds_m']=[[min(p[a] for p in pts) for a in range(3)],[max(p[a] for p in pts) for a in range(3)]]
plan={'schema':'datacenter-maze/v2','units':'meters','gallery_rectangles':rects,'floor_cells':sorted(cells),'cell_size_m':step,'ceiling_height_m':3.4,'wall_bounds_m':wall_bounds,'racks':racks,'route_points_m':route,'timeline':timeline,'camera':{'height_m':1.65,'lens_mm':24,'fps':24,'frames':720,'poses':poses},'landmarks':[{'id':'J1','color':'amber','position_m':[4,2.405,1.5]},{'id':'J2','color':'cyan','position_m':[-4.405,0,1.5]},{'id':'J3','color':'red','position_m':[-2,8.405,1.5]},{'id':'finish','color':'green','position_m':[-10.405,6,1.2]}],'local_import_repairs':repairs,'source_rack_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'evidence':'Authored synthetic benchmark, not measured real facility. Source-based rack exterior with local PSU repair.'}
(ROOT/'floor-plan.json').write_text(json.dumps(plan,indent=2));bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'datacenter-world.blend'),compress=True)
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
if 'save-only' not in args:
 for f in [1,145,193,313,361,481,529,649,719]:
  scene.frame_set(f);scene.render.filepath=str(OUT/f'frame-{f:04}.png');bpy.ops.render.render(write_still=True)
