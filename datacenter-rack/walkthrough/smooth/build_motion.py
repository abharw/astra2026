"""Continuous rounded walking turns; reuse the authored room without its labels."""
import bpy, math, json, bisect
from pathlib import Path
ROOT=Path(__file__).resolve().parent
bpy.ops.wm.open_mainfile(filepath=str(ROOT.parent/'datacenter-world.blend'))
scene=bpy.context.scene;camera=scene.camera
camera.animation_data_clear()
for obj in list(bpy.data.objects):
    if obj.type=='FONT': bpy.data.objects.remove(obj,do_unlink=True)
utility=bpy.data.materials.new('Ordinary unlabelled utility cabinet')
utility.diffuse_color=(.32,.34,.35,1);utility.use_nodes=True
bs=utility.node_tree.nodes.get('Principled BSDF');bs.inputs['Base Color'].default_value=utility.diffuse_color;bs.inputs['Roughness'].default_value=.65;bs.inputs['Metallic'].default_value=.25
for name in ['J1 amber identification panel','J2 cyan identification panel','J3 red identification panel','Destination green service door','Entry blue panel']:
    obj=bpy.data.objects[name];obj.data.materials.clear();obj.data.materials.append(utility)
# Two-sided cubic fillets maintain the route's left/right/left topology.
route=[(4,-6),(4,0),(-2,0),(-2,6),(-8,6)];radius=1.6
samples=[];weights=[]
def add_line(a,b):
    n=max(2,round(math.dist(a,b)*150))
    for k in range(n):
        u=k/n;samples.append(tuple(a[j]+u*(b[j]-a[j]) for j in range(2)));weights.append(1.0)
prev=route[0]
for i in range(1,4):
    p=route[i];a=route[i-1];b=route[i+1]
    vi=tuple((p[j]-a[j])/math.dist(p,a) for j in range(2));vo=tuple((b[j]-p[j])/math.dist(b,p) for j in range(2))
    entry=tuple(p[j]-radius*vi[j] for j in range(2));leave=tuple(p[j]+radius*vo[j] for j in range(2))
    add_line(prev,entry)
    # Quarter-circle cubic approximation, tangent to both straight aisles.
    k=.55228475
    c1=tuple(entry[j]+k*radius*vi[j] for j in range(2));c2=tuple(leave[j]-k*radius*vo[j] for j in range(2))
    for n in range(400):
        u=n/400;v=1-u
        samples.append(tuple(v**3*entry[j]+3*v*v*u*c1[j]+3*v*u*u*c2[j]+u**3*leave[j] for j in range(2)))
        weights.append(1.3)
    prev=leave
add_line(prev,route[-1]);samples.append(route[-1]);weights.append(1.0)
# Blend speed near straight/curve boundaries to avoid sudden acceleration.
weights=[sum(weights[max(0,min(len(weights)-1,i+j))] for j in range(-50,51))/101 for i in range(len(weights))]
length=[0.];clock=[0.]
for i in range(1,len(samples)):
    ds=math.dist(samples[i-1],samples[i]);length.append(length[-1]+ds);clock.append(clock[-1]+ds*(weights[i]+weights[i-1])/2)
def ease_walk(u):
    r=.055
    if u<r:return (u/2-r*math.sin(math.pi*u/r)/(2*math.pi))/(1-r)
    if u>1-r:return 1-ease_walk(1-u)
    return (u-r/2)/(1-r)
def at(t):
    value=ease_walk(max(0,min(1,t/23.5)))*clock[-1];i=max(1,min(len(clock)-1,bisect.bisect_left(clock,value)));u=(value-clock[i-1])/(clock[i]-clock[i-1])
    return tuple(samples[i-1][j]+u*(samples[i][j]-samples[i-1][j]) for j in range(2))
raw=[]
for f in range(720):
    t=f/24;x,y=at(t)
    if t<23.3:
        a=at(max(0,t-.15));b=at(min(23.5,t+.55))
        yaw=math.atan2(-(b[0]-a[0]),b[1]-a[1])
    else:yaw=math.pi/2
    raw.append((x,y,yaw))
# Anticipate each bend gently, rather than locking the head to path tangents.
yaws=[sum(raw[max(0,min(719,i+j))][2]*math.exp(-.5*(j/6)**2) for j in range(-18,19))/sum(math.exp(-.5*(j/6)**2) for j in range(-18,19)) for i in range(720)]
poses=[]
for f,(x,y,_) in enumerate(raw):
    t=f/24;yaw=yaws[f]
    if t>=23.5:
        u=(t-23.5)/6.5
        yaw=math.pi/2-math.radians(160)*(.5-.5*math.cos(math.pi*u))
    # Very restrained stabilized human motion, never abrupt camera shake.
    envelope=min(1,t/1.5,max(0,(24-t)/1.5))
    z=1.65+.003*math.sin(2*math.pi*t*1.4)*envelope
    pitch=math.pi/2+math.radians(.15)*math.sin(t*.8)*envelope
    camera.location=(x,y,z);camera.rotation_euler=(pitch,0,yaw)
    camera.keyframe_insert('location',frame=f+1);camera.keyframe_insert('rotation_euler',frame=f+1)
    poses.append({'frame':f+1,'time_s':t,'position_m':list(camera.location),'yaw_rad':yaw,'action':'continuous walk' if t<23.5 else 'slow look around'})
plan=json.loads((ROOT.parent/'floor-plan.json').read_text())
plan['camera']['poses']=poses
plan['landmarks']=[{'id':p['id'],'appearance':'plain unlabelled gray utility panel or door','position_m':p['position_m']} for p in plan['landmarks']]
plan['timeline']=[{'start_s':0,'end_s':23.5,'action':'continuous walking with rounded left, right, left turns'},{'start_s':23.5,'end_s':30,'action':'smooth clockwise 160 degree look around'}]
plan['motion']={'corner_radius_m':radius,'path_length_m':length[-1],'walk_end_s':23.5,'removed_all_text':True,'removed_colored_wayfinding':True}
speeds=[math.dist(poses[i]['position_m'],poses[i-1]['position_m'])*24 for i in range(1,720)]
rates=[abs(poses[i]['yaw_rad']-poses[i-1]['yaw_rad'])*24*180/math.pi for i in range(1,720)]
(ROOT/'motion-check.json').write_text(json.dumps({'maximum_speed_m_s':max(speeds),'maximum_pan_speed_deg_s':max(rates),'moving_samples_during_turns':sum(speeds[i]>.1 and rates[i]>5 for i in range(len(speeds))),'font_objects_remaining':sum(o.type=='FONT' for o in bpy.data.objects),'path_length_m':length[-1]},indent=2))
(ROOT/'floor-plan.json').write_text(json.dumps(plan,indent=2))
scene['scope']='Unlabelled ordinary facility, continuous rounded walking turns and slow final pan.'
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'datacenter-world.blend'),compress=True)
