"""Named, editable skeletal actions. Facial morphs are deliberately not keyed here."""
import bpy, math
from mathutils import Euler, Vector

def smooth(x):
    x=max(0,min(1,x));return x*x*(3-2*x)

MOTIONS={
 'idle':{'clip':'Idle','duration':4,'loop':True,'description':'Subtle breathing and relaxed posture'},
 'talk':{'clip':'Talking','duration':4,'loop':True,'description':'Small conversational head and hand gestures'},
 'wave':{'clip':'Wave','duration':3,'loop':False,'description':'Raise one hand and wave hello'},
 'nod':{'clip':'Nod','duration':1.8,'loop':False,'description':'Two small affirmative nods'},
 'shake_head':{'clip':'ShakeHead','duration':2,'loop':False,'description':'A gentle no gesture'},
 'shrug':{'clip':'Shrug','duration':2.6,'loop':False,'description':'Lift both arms and shoulders'},
 'think':{'clip':'Thinking','duration':3.2,'loop':False,'description':'Tilt the head and bring a hand toward the chest'},
 'cheer':{'clip':'Cheer','duration':3,'loop':False,'description':'Raise both hands with a little body bounce'},
 'listen':{'clip':'Listening','duration':4,'loop':True,'description':'Attentive head tilt and small acknowledging nod'},
}

def values(name,t,duration):
    u=t/duration;env=smooth(t/.55)*(1-smooth((t-(duration-.55))/.55));s=math.sin;pi=math.pi
    out={};loc={}
    # Tuples are world-oriented pitch/yaw/roll in the exported Y-up character frame.
    if name=='idle':
        out={'torso':(.01*s(2*pi*u),0,.009*s(2*pi*u)),'head':(.015*s(2*pi*u),.022*s(2*pi*u),.012*s(2*pi*u))};loc={'torso':(0,0,.006*s(2*pi*u))}
    elif name=='talk':
        out={'head':(.045*s(4*pi*u),.055*s(2*pi*u),.025*s(2*pi*u)), 'upper_arm.R':(-.12-.06*s(4*pi*u),0,.13+.09*s(2*pi*u)), 'forearm.R':(-.18-.06*s(4*pi*u),0,.18+.10*s(4*pi*u)), 'upper_arm.L':(-.09-.04*s(4*pi*u),0,-.08-.045*s(4*pi*u)), 'forearm.L':(-.10,0,-.1-.08*s(2*pi*u))}
    elif name=='wave':
        out={'upper_arm.R':(0,0,1.745*env),'forearm.R':(-.12*env,0,.436*env),'hand.R':(0,.10*env,.28*s(2*pi*t*2.3)*env),'head':(0,.04*env,-.06*env)}
    elif name=='nod':out={'head':(.22*s(4*pi*u)*s(pi*u)**2,0,0)}
    elif name=='shake_head':out={'head':(0,.32*s(4*pi*u)*s(pi*u)**2,0)}
    elif name=='shrug':
        out={'upper_arm.R':(-.18*env,0,.50*env),'upper_arm.L':(-.18*env,0,-.50*env),'forearm.R':(-.32*env,0,.65*env),'forearm.L':(-.32*env,0,-.65*env),'head':(-.06*env,0,.04*env)};loc={'torso':(0,0,.055*env)}
    elif name=='think':out={'upper_arm.R':(-.32*env,0,.85*env),'forearm.R':(-.9*env,0,1.55*env),'head':(.10*env,-.10*env,.13*env)}
    elif name=='cheer':
        out={'upper_arm.R':(0,0,2.10*env),'upper_arm.L':(0,0,-2.10*env),'forearm.R':(-.10*env,0,.22*env),'forearm.L':(-.10*env,0,-.22*env),'head':(-.08*env,0,0)};loc={'root':(0,0,.08*env*max(0,s(pi*t*2)))}
    elif name=='listen':out={'head':(.025+.035*s(4*pi*u),-.06,.10+.018*s(2*pi*u))}
    return out,loc

def apply(rig,name,t,duration):
    rotations,locations=values(name,t,duration)
    for b in rig.pose.bones:
        b.rotation_mode='QUATERNION';rest=b.bone.matrix_local.to_quaternion();pitch,yaw,roll=rotations.get(b.name,(0,0,0));world=Euler((pitch,-roll,yaw),'XYZ').to_quaternion()
        b.rotation_quaternion=rest.inverted()@world@rest
        b.location=rest.inverted()@Vector(locations.get(b.name,(0,0,0)))
    bpy.context.view_layer.update()

def create_actions(rig):
    rig.animation_data_create();scene=bpy.context.scene
    for name,info in MOTIONS.items():
        action=bpy.data.actions.new(info['clip']);rig.animation_data.action=action
        steps=round(info['duration']*30)
        for n in range(steps+1):
            apply(rig,name,n/30,info['duration'])
            for b in rig.pose.bones:
                b.keyframe_insert('rotation_quaternion',frame=n+1,group=b.name)
                b.keyframe_insert('location',frame=n+1,group=b.name)
        action.use_fake_user=True;action['description']=info['description'];action['loop']=info['loop'];action.asset_mark()
        # Each action belongs to the same armature and remains discoverable in the .blend.
    rig.animation_data.action=None;apply(rig,'idle',0,4);scene.frame_set(1)
    return MOTIONS
