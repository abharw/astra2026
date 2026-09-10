"""Blender Python helpers. Run this text, then call set_expression()/play_motion()."""
import bpy, json
from pathlib import Path
_MANIFEST = json.loads((Path(bpy.data.filepath).parent/'character.json').read_text())

def set_controls(values, reset=False):
    unknown=set(values)-set(_MANIFEST['controls'])
    if unknown: raise ValueError(f'Unknown controls: {unknown}')
    control=bpy.data.objects['FACE_CONTROLS']
    if reset:
        for key in _MANIFEST['controls']: control[key]=0.0
    for key,value in values.items(): control[key]=max(0.0,min(1.0,float(value)))
    control.update_tag(refresh={'OBJECT'});bpy.context.view_layer.update()
    bpy.context.scene.frame_set(bpy.context.scene.frame_current)

def set_expression(name='neutral', strength=1.0):
    set_controls({k:v*strength for k,v in _MANIFEST['expressions'][name].items()}, reset=True)

def set_viseme(name='rest', weight=1.0):
    controls={k:0.0 for k in ['jawOpen','mouthPucker','mouthWide','mouthClose']}
    controls.update({k:v*weight for k,v in _MANIFEST['visemes'][name].items()});set_controls(controls)

def set_mouth(opening):
    set_controls({'jawOpen':opening,'mouthClose':0.0})

def play_motion(name='idle'):
    meta=_MANIFEST['motions'][name];rig=bpy.data.objects['Astra_Rig'];rig.animation_data_create()
    rig.animation_data.action=bpy.data.actions[meta['clip']]
    if rig.animation_data.action.slots: rig.animation_data.action_slot=rig.animation_data.action.slots[0]
    scene=bpy.context.scene;scene.frame_start=1;scene.frame_end=round(meta['duration']*scene.render.fps)+1;scene.frame_set(1)
    return rig.animation_data.action
