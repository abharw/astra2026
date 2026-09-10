"""Authored Astro-inspired girl. Run with Blender 5.2+, no external art assets."""
import bpy, math, json, sys
from mathutils import Vector
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
ASSETS=ROOT/'assets'; PREV=ROOT/'previews'
for p in [ASSETS,PREV]: p.mkdir(exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene=bpy.context.scene
scene.unit_settings.system='METRIC'
COL=bpy.data.collections.new('ASTRA GIRL · character');scene.collection.children.link(COL)
objects=[];groups={}
CONTROLS=['jawOpen','mouthSmile','mouthFrown','mouthPucker','mouthWide','mouthClose','eyeBlinkLeft','eyeBlinkRight','eyeWideLeft','eyeWideRight','browInnerUp','browDownLeft','browDownRight','browOuterUpLeft','browOuterUpRight']
PRESETS={
 'neutral':{},
 'happy':{'mouthSmile':.85,'jawOpen':.20,'browOuterUpLeft':.2,'browOuterUpRight':.2},
 'sad':{'mouthFrown':.8,'browInnerUp':.85},
 'angry':{'browDownLeft':.9,'browDownRight':.9,'mouthFrown':.45,'jawOpen':.08},
 'surprised':{'jawOpen':.8,'mouthPucker':.45,'eyeWideLeft':.8,'eyeWideRight':.8,'browInnerUp':.6,'browOuterUpLeft':.75,'browOuterUpRight':.75},
 'thinking':{'browOuterUpLeft':.75,'browDownRight':.25,'mouthPucker':.35},
 'wink':{'eyeBlinkLeft':1,'mouthSmile':.8,'browOuterUpRight':.35},
 'sleepy':{'eyeBlinkLeft':.78,'eyeBlinkRight':.78,'mouthSmile':.15},
}
VISEMES={'rest':{},'aa':{'jawOpen':.9,'mouthWide':.12},'ee':{'jawOpen':.25,'mouthWide':.9},'ih':{'jawOpen':.4,'mouthWide':.35},'oh':{'jawOpen':.7,'mouthPucker':.8},'ou':{'jawOpen':.3,'mouthPucker':1},'mbp':{'mouthClose':1},'fv':{'jawOpen':.12,'mouthWide':.45}}

def material(name,color,metal=0,rough=.45):
    m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True
    n=m.node_tree.nodes.get('Principled BSDF');n.inputs['Base Color'].default_value=(*color,1);n.inputs['Metallic'].default_value=metal;n.inputs['Roughness'].default_value=rough
    return m
skin=material('warm porcelain skin',(.96,.65,.43),0,.58)
ivory=material('warm ivory enamel',(.92,.92,.83),.05,.32)
hair=material('ink black · soft blue sheen',(.012,.019,.031),.12,.26)
red=material('vermilion enamel',(.72,.035,.028),.16,.3)
red_dark=material('boot sole',(.18,.018,.018),.06,.47)
mint=material('mint green belt',(.10,.57,.40),.15,.33)
gold=material('brushed champagne metal',(.86,.53,.15),.62,.31)
white=material('eye white',(.97,.99,1),0,.31)
iris=material('warm hazel iris',(.29,.105,.035),.04,.33)
black=material('eye ink',(.009,.008,.016),0,.38)
blush=material('soft coral cheeks',(.94,.36,.28),0,.68)
mouthmat=material('mouth interior',(.095,.013,.026),0,.78)
lipmat=material('mouth contour',(.30,.055,.065),0,.65)
tonguemat=material('tongue',(.81,.18,.26),0,.53)


def finish(o,name,mat,bone='head'):
    o.name=name
    for c in list(o.users_collection):c.objects.unlink(o)
    COL.objects.link(o)
    if mat:o.data.materials.append(mat)
    if o.type=='MESH':
        for f in o.data.polygons:f.use_smooth=True
    objects.append(o);groups[o.name]=bone
    return o

def uv(name,loc,scale,mat,bone='head',seg=48,rings=28):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=seg,ring_count=rings,location=loc)
    o=bpy.context.object;o.scale=scale
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    return finish(o,name,mat,bone)

def mesh(name,verts,faces,mat,bone='head'):
    d=bpy.data.meshes.new(name);d.from_pydata(verts,[],faces);d.update();o=bpy.data.objects.new(name,d);COL.objects.link(o)
    return finish(o,name,mat,bone)

def curve(name,points,radius,mat,bone='head'):
    c=bpy.data.curves.new(name,'CURVE');c.dimensions='3D';c.resolution_u=16;c.bevel_depth=radius;c.bevel_resolution=3
    s=c.splines.new('BEZIER');s.bezier_points.add(len(points)-1)
    for b,p in zip(s.bezier_points,points):b.co=p;b.handle_left_type='AUTO';b.handle_right_type='AUTO'
    o=bpy.data.objects.new(name,c);COL.objects.link(o)
    bpy.context.view_layer.objects.active=o;o.select_set(True);bpy.ops.object.convert(target='MESH');o=bpy.context.object;o.select_set(False)
    return finish(o,name,mat,bone)

def capsule(name,a,b,r,mat,bone):
    mid=(Vector(a)+Vector(b))/2
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32,ring_count=20,location=mid)
    o=bpy.context.object;o.scale=(r,r,(Vector(b)-Vector(a)).length/2+r*.45);o.rotation_euler=(Vector(b)-Vector(a)).to_track_quat('Z','Y').to_euler()
    bpy.ops.object.transform_apply(location=True,rotation=True,scale=True)
    return finish(o,name,mat,bone)

def ring_shape(name,rings,mat,bone):
    vs=[];fs=[];n=64
    for z,rx,ry,cy in rings:
        for i in range(n):
            a=2*math.pi*i/n;vs.append((rx*math.cos(a),cy+ry*math.sin(a),z))
    for j in range(len(rings)-1):
        for i in range(n):a=j*n+i;b=j*n+(i+1)%n;fs.append((a,b,b+n,a+n))
    fs.append(tuple(range(n-1,-1,-1)));fs.append(tuple((len(rings)-1)*n+i for i in range(n)))
    return mesh(name,vs,fs,mat,bone)

def shape(o,name,fn):
    if not o.data.shape_keys:o.shape_key_add(name='Basis')
    k=o.shape_key_add(name=name);basis=o.data.shape_keys.key_blocks['Basis']
    for v,b in zip(k.data,basis.data):v.co=fn(b.co.copy())
    k.slider_min=0;k.slider_max=1
    return k

HC=Vector((0,0,2.51)); HS=(.79,.655,.85)
def front_y(x,z):
    r=1-(x/HS[0])**2-((z-HC.z)/HS[2])**2
    return -HS[1]*math.sqrt(max(.035,r))

# Rounded cheeks, broad forehead, and a subtle chin. Vertex topology stays fixed.
head=uv('Face',HC,HS,skin,seg=64,rings=40)
for v in head.data.vertices:
    z=v.co.z
    if z<2.27:v.co.x*=1-.12*max(0,(2.27-z)/.62)
shape(head,'jawOpen',lambda v:Vector((v.x,v.y,v.z-.04*max(0,min(1,(2.33-v.z)/.5)))))
uv('Ear.L',(-.765,-.015,2.40),(.16,.13,.205),skin)
uv('Ear.R',(.765,-.015,2.40),(.16,.13,.205),skin)
uv('Ear inset.L',(-.84,-.102,2.40),(.063,.038,.108),blush)
uv('Ear inset.R',(.84,-.102,2.40),(.063,.038,.108),blush)
uv('Nose',(0,-.664,2.40),(.075,.097,.081),skin)
for side in [-1,1]:
    x=side*.475;z=2.35
    uv('Cheek blush.'+str(side),(x,front_y(x,z)-.018,z),(.095,.015,.041),blush)

# Sculpted cap: M-shaped forehead fringe and a short curved bob at the back.
vs=[];fs=[];nr=28;ns=96
for j in range(nr+1):
    f=j/nr
    for i in range(ns):
        phi=2*math.pi*i/ns;ax=abs(math.cos(phi));front=max(0,min(1,(-math.sin(phi)-.05)/.3))
        hairline=3.035+.12*math.sin(math.pi*ax)-.43*ax**6
        fronttheta=math.acos(max(-.98,min(.98,(hairline-2.51)/.89)))
        maxtheta=front*fronttheta+(1-front)*2.16
        theta=.0003+f*maxtheta
        vs.append((.826*math.sin(theta)*math.cos(phi),.695*math.sin(theta)*math.sin(phi)+.03,2.51+.89*math.cos(theta)))
for j in range(nr):
    for i in range(ns):a=j*ns+i;b=j*ns+(i+1)%ns;fs.append((a,b,b+ns,a+ns))
cap=mesh('Pointed bob · cap',vs,fs,hair)
# Swept, non-conical hair locks taper along a curved centerline.
def lock(name,points,radii):
    vs=[];fs=[];sides=24
    for j,(p,rad) in enumerate(zip(points,radii)):
        tangent=Vector(points[min(j+1,len(points)-1)])-Vector(points[max(0,j-1)])
        tangent.normalize();u=tangent.cross(Vector((0,1,0))).normalized();v=tangent.cross(u).normalized()
        for i in range(sides):
            t=2*math.pi*i/sides;vs.append(Vector(p)+rad*(math.cos(t)*u+.72*math.sin(t)*v))
    for j in range(len(points)-1):
        for i in range(sides):a=j*sides+i;b=j*sides+(i+1)%sides;fs.append((a,b,b+sides,a+sides))
    o=mesh(name,vs,fs,hair)
    sub=o.modifiers.new('soft sculpted lock','SUBSURF');sub.levels=2
    bpy.context.view_layer.objects.active=o;bpy.ops.object.modifier_apply(modifier=sub.name)
    return o
lock('Signature crown point',[(.18,.10,3.17),(.30,.13,3.36),(.37,.17,3.55),(.38,.20,3.74)],[.30,.22,.12,.006])
lock('Left swept point',[(-.54,.05,2.89),(-.77,.07,2.96),(-.96,.10,3.10),(-1.04,.11,3.25)],[.30,.24,.13,.005])
lock('Right bob flick',[(.60,.10,2.47),(.77,.12,2.37),(.89,.16,2.31),(.97,.18,2.38)],[.22,.17,.10,.005])
lock('Left bob flick',[(-.60,.16,2.28),(-.75,.17,2.16),(-.89,.20,2.12),(-.99,.22,2.20)],[.23,.16,.09,.005])
# Discrete mint barrette: a designed asymmetric detail.
bar=curve('Mint barrette',[(.49,-.477,3.13),(.55,-.433,3.11),(.60,-.391,3.07)],.036,mint)
uv('Barrette rivet',(.56,-.467,3.125),(.022,.018,.022),gold)

# Eyes are separate editable meshes; all constituent shapes blink together.
for side,label in [(-1,'Left'),(1,'Right')]:
    x=side*.287;z=2.66;eye_parts=[]
    eye_parts.append(uv('Sclera.'+label,(x,-.572,z),(.238,.141,.298),white))
    eye_parts.append(uv('Iris.'+label,(x+side*.005,-.706,z-.012),(.122,.027,.205),iris))
    eye_parts.append(uv('Pupil.'+label,(x+side*.008,-.73,z-.010),(.083,.018,.169),black))
    eye_parts.append(uv('Catchlight.'+label,(x-.033,-.75,z+.070),(.034,.008,.049),white,seg=24,rings=16))
    eye_parts.append(uv('Catchlight small.'+label,(x+.046,-.751,z-.096),(.017,.006,.023),white,seg=20,rings=12))
    for o in eye_parts:
        shape(o,'eyeBlink'+label,lambda v,z=z:Vector((v.x,v.y+.25,z-.08+(v.z-z)*.015)))
        shape(o,'eyeWide'+label,lambda v,z=z:Vector((v.x,v.y-.006,z+(v.z-z)*1.15)))
    pts=[]
    for k in range(9):
        a=math.pi*k/8;xx=x+.235*math.cos(a);zz=z+.296*math.sin(a);yy=-.58-.08*math.sin(a)
        pts.append((xx,yy,zz))
    liner=curve('Upper lash line.'+label,pts,.016,black)
    shape(liner,'eyeBlink'+label,lambda v,x=x,z=z:Vector((v.x,-.685,z-.09+.045*((v.x-x)/.24)**2)))
    shape(liner,'eyeWide'+label,lambda v,z=z:Vector((v.x,v.y,z+(v.z-z)*1.15)))
    for k in range(2):
        a=(.20+.20*k) if side==1 else math.pi-(.20+.20*k)
        xx=x+.23*math.cos(a);zz=z+.29*math.sin(a)
        lash=curve('Lash.'+label+str(k),[(xx,-.611,zz),(xx+side*.055,-.621,zz+.055),(xx+side*.073,-.615,zz+.092)],.012,black)
        shape(lash,'eyeBlink'+label,lambda v,z=z:Vector((v.x,v.y+.01,z-.05+(v.z-z)*.02)))
    closedpts=[]
    for n in range(7):
        xx=x-.205+n*.410/6;zz=z-.082+.032*((xx-x)/.205)**2
        closedpts.append((xx,front_y(xx,zz)+.042,zz))
    closed=curve('Closed eyelid.'+label,closedpts,.016,black)
    shape(closed,'eyeBlink'+label,lambda v:Vector((v.x,v.y-.10,v.z)))
    browpoints=[(x-.16,-.555,3.003),(x,-.591,3.068),(x+.16,-.552,3.019)]
    brow=curve('Brow.'+label,browpoints,.028,hair)
    shape(brow,'browInnerUp',lambda v,side=side,x=x:Vector((v.x,v.y-.025,v.z+.11*max(0,1-side*(v.x-x)/.16)/2)))
    shape(brow,'browDown'+label,lambda v,side=side,x=x:Vector((v.x,v.y-.04,v.z-.16*(1-side*(v.x-x)/.23)/2)))
    shape(brow,'browOuterUp'+label,lambda v,side=side,x=x:Vector((v.x,v.y-.02,v.z+.13*(1+side*(v.x-x)/.23)/2)))

# Mouth surfaces share an exact parametric contour; independent relative keys blend.
MZ=2.18;MW=.195

def mouth_coord(u,r,kind='Basis',depth=.052):
    c=math.cos(u);s=math.sin(u);width=MW;amp=.014;offset=0.;curve=.022
    if kind=='jawOpen':width+=.012;amp=.106;offset=-.078
    if kind=='mouthSmile':width+=.045;amp=.020;curve=.100;offset=-.008
    if kind=='mouthFrown':curve=-.072;offset=.015
    if kind=='mouthPucker':width=.108;amp=.042;curve=.014
    if kind=='mouthWide':width=.272;amp=.018
    if kind=='mouthClose':width=.181;amp=.004
    # A smooth elliptical disk follows the mouth center. Scaling the entire
    # contour around a fixed point folds interior fans during combined poses.
    x=width*c*r;z=MZ+offset+amp*s*r+curve*(c*r)**2
    return Vector((x,front_y(x,z)-depth,z))

N=64;nr=5
vs=[mouth_coord(0,0)]
for j in range(1,nr+1):
    for i in range(N):vs.append(mouth_coord(2*math.pi*i/N,j/nr))
fs=[]
for i in range(N):fs.append((0,1+i,1+(i+1)%N))
for j in range(nr-1):
    for i in range(N):a=1+j*N+i;b=1+j*N+(i+1)%N;fs.append((a,b,b+N,a+N))
cavity=mesh('Mouth · cavity',vs,fs,mouthmat)
keys=CONTROLS[:6]
for name in keys:
    cavity.shape_key_add(name='Basis') if not cavity.data.shape_keys else None
    k=cavity.shape_key_add(name=name);k.data[0].co=mouth_coord(0,0,name)
    for j in range(1,nr+1):
        for i in range(N):k.data[1+(j-1)*N+i].co=mouth_coord(2*math.pi*i/N,j/nr,name)
# Contour ribbon. Its vertical thickness stays small while the opening changes.
vs=[];fs=[]
for j in range(2):
    for i in range(N):
        u=2*math.pi*i/N;p=mouth_coord(u,1,depth=.058);p.x+=(j*2-1)*.009*math.cos(u);p.z+=(j*2-1)*.009*math.sin(u);vs.append(p)
for i in range(N):fs.append((i,(i+1)%N,(i+1)%N+N,i+N))
lips=mesh('Mouth · contour',vs,fs,lipmat)
lips.shape_key_add(name='Basis')
for name in keys:
    k=lips.shape_key_add(name=name)
    for j in range(2):
        for i in range(N):
            u=2*math.pi*i/N;p=mouth_coord(u,1,name,.058);p.x+=(j*2-1)*.009*math.cos(u);p.z+=(j*2-1)*.009*math.sin(u);k.data[j*N+i].co=p
# Small tongue reveals only on an open jaw. Baseline lies inside the head.
tongue=uv('Mouth · tongue',(0,-.52,2.18),(.108,.025,.014),tonguemat,seg=32,rings=16)
shape(tongue,'jawOpen',lambda v:Vector((v.x, v.y-.105,2.043+(v.z-2.18)*2.4)))
shape(tongue,'mouthPucker',lambda v:Vector((v.x*.6,v.y,v.z)))

# Covered retro robot outfit, mint waist band, and oversized red rocket boots.
uv('Neck',(0,0,1.79),(.19,.18,.27),skin,'torso')
ring_shape('Ivory tunic',[(1.19,.40,.255,0),(1.24,.405,.26,0),(1.63,.435,.27,0),(1.76,.33,.225,0),(1.80,.22,.18,0)],ivory,'torso')
ring_shape('Red flared tunic hem',[(.99,.49,.30,0),(1.035,.51,.31,0),(1.18,.425,.27,0),(1.28,.395,.25,0)],red,'torso')
ring_shape('Mint waist belt',[(1.205,.416,.273,0),(1.23,.425,.28,0),(1.30,.412,.27,0),(1.315,.402,.262,0)],mint,'torso')
ring_shape('Red collar',[(1.755,.22,.19,0),(1.78,.23,.195,0),(1.825,.207,.18,0)],red,'torso')
uv('Chest badge rim',(0,-.285,1.55),(.122,.027,.122),gold,'torso')
uv('Chest badge mint',(0,-.309,1.55),(.091,.018,.091),mint,'torso')
curve('Badge glint',[(-.036,-.329,1.59),(-.006,-.332,1.614),(.029,-.329,1.60)],.009,ivory,'torso')
uv('Belt clasp',(0,-.287,1.26),(.074,.025,.064),gold,'torso')
for side,label in [(-1,'L'),(1,'R')]:
    arm='upper_arm.'+label;fore='forearm.'+label;hand='hand.'+label;leg='thigh.'+label;shin='shin.'+label;foot='foot.'+label
    uv('Shoulder shell.'+label,(side*.405,0,1.63),(.203,.205,.218),ivory,arm)
    capsule('Upper arm.'+label,(side*.49,0,1.57),(side*.635,-.02,1.32),.13,skin,arm)
    uv('Elbow seam.'+label,(side*.64,-.022,1.31),(.13,.132,.12),red,fore)
    capsule('Forearm.'+label,(side*.65,-.028,1.27),(side*.73,-.062,1.08),.126,skin,fore)
    uv('Glove cuff.'+label,(side*.745,-.059,1.025),(.144,.14,.073),red,hand)
    uv('Mitten.'+label,(side*.762,-.075,.923),(.16,.135,.17),ivory,hand)
    uv('Thumb.'+label,(side*.647,-.142,.972),(.084,.082,.103),ivory,hand)
    for k in [-1,0,1]:
        xx=side*.762+k*.053;curve('Glove seam.'+label+str(k),[(xx,-.204,.965),(xx,-.211,.926),(xx,-.204,.9)],.004,gold,hand)
    capsule('Leg.'+label,(side*.243,0,.99),(side*.25,0,.61),.165,ivory,leg)
    uv('Knee seam.'+label,(side*.25,0,.655),(.174,.172,.060),red,shin)
    capsule('Boot shaft.'+label,(side*.25,0,.58),(side*.25,-.025,.255),.214,red,shin)
    uv('Boot cuff.'+label,(side*.25,0,.58),(.237,.234,.093),red,shin)
    uv('Boot toe.'+label,(side*.25,-.115,.168),(.252,.348,.164),red,foot)
    uv('Boot sole.'+label,(side*.25,-.105,.064),(.254,.348,.061),red_dark,foot)
    uv('Rocket port.'+label,(side*.25,.20,.22),(.11,.04,.093),gold,foot)
    curve('Boot highlight seam.'+label,[(side*.25-.105,-.323,.245),(side*.25,-.36,.264),(side*.25+.105,-.323,.245)],.011,red_dark,foot)

# Small rigid-part skeleton. Face morphs remain independent of head movement.
armdata=bpy.data.armatures.new('Astra skeleton');rig=bpy.data.objects.new('Astra_Rig',armdata);COL.objects.link(rig)
bpy.context.view_layer.objects.active=rig;rig.select_set(True);bpy.ops.object.mode_set(mode='EDIT')
bones={'root':((0,0,0),(0,0,1.05),None),'torso':((0,0,1.05),(0,0,1.77),'root'),'head':((0,0,1.77),(0,0,2.51),'torso')}
for side,l in [(-1,'L'),(1,'R')]:
    bones.update({f'upper_arm.{l}':((side*.41,0,1.64),(side*.64,-.02,1.31),'torso'),f'forearm.{l}':((side*.64,-.02,1.31),(side*.74,-.06,1.03),f'upper_arm.{l}'),f'hand.{l}':((side*.74,-.06,1.03),(side*.76,-.075,.88),f'forearm.{l}'),f'thigh.{l}':((side*.24,0,1.07),(side*.25,0,.65),'root'),f'shin.{l}':((side*.25,0,.65),(side*.25,-.025,.22),f'thigh.{l}'),f'foot.{l}':((side*.25,-.025,.22),(side*.25,-.28,.16),f'shin.{l}')})
for name,(a,b,parent) in bones.items():
    bone=armdata.edit_bones.new(name);bone.head=a;bone.tail=b
    if parent:bone.parent=armdata.edit_bones[parent]
bpy.ops.object.mode_set(mode='OBJECT');rig.show_in_front=True;rig.select_set(False)
for o in objects:
    if o.type!='MESH':continue
    vg=o.vertex_groups.new(name=groups[o.name]);vg.add(list(range(len(o.data.vertices))),1,'REPLACE')
    mod=o.modifiers.new('Astra skeleton','ARMATURE');mod.object=rig;o.parent=rig
    o['avatar_part']=groups[o.name]
ctrl=bpy.data.objects.new('FACE_CONTROLS',None);COL.objects.link(ctrl);ctrl.empty_display_type='PLAIN_AXES';ctrl.empty_display_size=.1;ctrl.location=(1.3,0,2.5)
for key in CONTROLS:
    ctrl[key]=0.;ctrl.id_properties_ui(key).update(min=0.,max=1.,description='Normalized facial control; 0 is neutral and 1 is full influence.')
for o in objects:
    if o.type=='MESH' and o.data.shape_keys:
        for key in o.data.shape_keys.key_blocks:
            if key.name=='Basis':continue
            d=key.driver_add('value').driver;d.type='SCRIPTED';v=d.variables.new();v.name='v';v.type='SINGLE_PROP';v.targets[0].id=ctrl;v.targets[0].data_path='["'+key.name+'"]';d.expression='min(1,max(0,v))'
        o['morph_controls']=[k.name for k in o.data.shape_keys.key_blocks if k.name!='Basis']
rig['character']='Astra Girl · authored Astro-inspired fan character';rig['front_axis']='-Y';rig['up_axis']='Z';rig['rig_version']='1.0';rig['expressions']=json.dumps(PRESETS)

def pose(values):
    for k in CONTROLS:ctrl[k]=float(values.get(k,0))
    ctrl.update_tag(refresh={'OBJECT'});bpy.context.view_layer.update();scene.frame_set(scene.frame_current)

# Studio objects stay out of exported avatar.
world=bpy.data.worlds.new('warm studio');world.use_nodes=True;world.node_tree.nodes['Background'].inputs[0].default_value=(.55,.67,.68,1);world.node_tree.nodes['Background'].inputs[1].default_value=.35;scene.world=world
bpy.ops.mesh.primitive_plane_add(size=200);floor=bpy.context.object;floor.name='Studio ground';floor.data.materials.append(material('studio sage',(.34,.46,.42),0,.78))
def area(name,loc,power,color,size):
    ld=bpy.data.lights.new(name,'AREA');ld.energy=power;ld.color=color;ld.shape='DISK';ld.size=size;o=bpy.data.objects.new(name,ld);scene.collection.objects.link(o);o.location=loc;o.rotation_euler=(Vector((0,0,2))-o.location).to_track_quat('-Z','Y').to_euler()
area('Key softbox',(-3.5,-5,6),650,(1,.88,.73),4)
area('Fill softbox',(3.3,-2.5,4),400,(.72,.86,1),3.3)
area('Hair rim',(1.2,3,5),850,(1,.8,.57),3)
cd=bpy.data.cameras.new('Portrait camera');cam=bpy.data.objects.new('Portrait camera',cd);scene.collection.objects.link(cam);scene.camera=cam;cd.type='ORTHO';cd.ortho_scale=4.25;cam.location=(4,-10,4.3);cam.rotation_euler=(Vector((0,0,1.87))-cam.location).to_track_quat('-Z','Y').to_euler()
scene.render.engine='BLENDER_EEVEE';scene.eevee.taa_render_samples=48;scene.render.resolution_x=1200;scene.render.resolution_y=1200;scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.view_settings.view_transform='AgX';scene.render.film_transparent=False
scene.render.fps=30;scene.frame_start=1;scene.frame_end=300
pose({})
sys.path.insert(0,str(ROOT/'src'))
from motions import create_actions, apply as apply_motion
MOTIONS=create_actions(rig)
# GLB has portable morph targets; runtime performs control mapping instead of drivers.
bpy.ops.object.select_all(action='DESELECT')
for o in objects+[rig]:o.select_set(True)
bpy.context.view_layer.objects.active=rig
bpy.ops.export_scene.gltf(filepath=str(ASSETS/'astra-girl.glb'),export_format='GLB',use_selection=True,export_extras=True,export_animations=True,export_animation_mode='ACTIONS',export_anim_single_armature=True,export_morph_animation=False,export_skins=True,export_morph=True,export_apply=False)
bpy.ops.object.select_all(action='DESELECT');ctrl.select_set(True);bpy.context.view_layer.objects.active=ctrl
for screen in bpy.data.screens:
    for a in screen.areas:
        if a.type=='VIEW_3D':a.spaces.active.region_3d.view_perspective='CAMERA'
summary={'name':'Astra Girl','version':'1.0','authorship':'Fresh authored geometry, Astro Boy / Uran inspired fan character; no downloaded model used.','controls':CONTROLS,'expressions':PRESETS,'visemes':VISEMES,'motions':MOTIONS,'bones':list(bones),'meshes':len(objects),'vertices':sum(len(o.data.vertices) for o in objects if o.type=='MESH'),'triangles':sum(sum(max(0,len(p.vertices)-2) for p in o.data.polygons) for o in objects if o.type=='MESH'),'morph_meshes':{o.name:[k.name for k in o.data.shape_keys.key_blocks if k.name!='Basis'] for o in objects if o.type=='MESH' and o.data.shape_keys},'blender_controls_object':'FACE_CONTROLS','runtime':'GLB morph targets; JavaScript controls included; Blender drivers do not execute outside Blender.'}
(ASSETS/'character.json').write_text(json.dumps(summary,indent=2))
text=bpy.data.texts.new('README · facial controls');text.write('ASTRA GIRL\nSelect FACE_CONTROLS and open Object Properties > Custom Properties. Each facial control ranges 0..1.\nRelative shape keys are on face, eye, brow and mouth meshes. Head and body use Astra_Rig.\nUse the included viewer or GLB morph targets for live voice control.\nNamed presets and visemes are in assets/character.json.\n')
bpy.data.texts.new('control_character.py').write((ROOT/'src'/'control_character.py').read_text())
bpy.ops.wm.save_as_mainfile(filepath=str(ASSETS/'astra-girl.blend'),compress=True)
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
if 'no-render' not in args:
    pose(PRESETS['happy']);scene.render.filepath=str(PREV/'hero.png');bpy.ops.render.render(write_still=True)
    cd.ortho_scale=2.45;cam.location=(0,-9,3.02);cam.rotation_euler=(Vector((0,-.03,2.67))-cam.location).to_track_quat('-Z','Y').to_euler();scene.render.resolution_x=600;scene.render.resolution_y=600;scene.eevee.taa_render_samples=32
    for name,values in PRESETS.items():
        pose(values);scene.render.filepath=str(PREV/(name+'.png'));bpy.ops.render.render(write_still=True)
    cd.ortho_scale=4.3;cam.location=(3,-10,4);cam.rotation_euler=(Vector((0,0,1.85))-cam.location).to_track_quat('-Z','Y').to_euler();scene.render.resolution_x=600;scene.render.resolution_y=720
    for name,info in MOTIONS.items():
        pose(PRESETS['happy'] if name in ['wave','cheer','talk'] else PRESETS['thinking'] if name=='think' else {})
        apply_motion(rig,name,info['duration']*.4,info['duration']);scene.render.filepath=str(PREV/('motion-'+name+'.png'));bpy.ops.render.render(write_still=True)
print('ASTRA_GIRL_BUILD_COMPLETE',json.dumps({k:summary[k] for k in ['meshes','vertices','triangles']}))
