import bpy,sys,pathlib,json
from mathutils import Vector
BASE=pathlib.Path('/Users/akeilsmith/Documents/Codex/2026-09-04/is-x20/outputs/astra2026-rack/datacenter-rack')
sys.path.insert(0,str(BASE/'source'));import rack_frame,rack_cabling
bpy.ops.wm.read_factory_settings(use_empty=True)
rack=rack_frame.build_rack();r=rack_cabling.build_cabling(rack['server_slot_origins'],rack['root']);bpy.context.view_layer.update()
checks={'external_count':len(r['external_curves'])==18,'patch_ports':r['metadata']['patch_ports']==36,'curves_editable_bezier':all(o.type=='CURVE' and o.data.splines[0].type=='BEZIER' for o in r['curves']),'endpoint_metadata':all(o.get('endpoint_from') and o.get('endpoint_to') for o in r['curves']),'inferred_routing_tagged':all(o.get('evidence_level')=='inferred-routing' for o in r['curves']),'body_front_clearance_control_points':all(max(p.co.y for p in o.data.splines[0].bezier_points)<-.425 for o in r['external_curves'])}
checks['finite_control_points']=all(abs(v)<100 for o in r['curves'] for p in o.data.splines[0].bezier_points for v in p.co)
assert all(checks.values()),checks
report={'checks':checks,'metadata':r['metadata'],'objects':len(r['objects']),'internal_endpoints':{o.name:r['endpoints'].get(o.name) for o in r['internal_curves']}}
(BASE/'logs/cabling-validation.json').write_text(json.dumps(report,indent=2))
scene=bpy.context.scene;scene.render.engine='BLENDER_WORKBENCH';scene.world=bpy.data.worlds.new('Cabling QA world');scene.world.color=(.14,.14,.14);scene.display.shading.light='STUDIO';scene.display.shading.color_type='MATERIAL';scene.display.shading.show_shadows=True;scene.display.shading.show_cavity=True;scene.display.shading.cavity_type='BOTH'
scene.render.resolution_x=1200;scene.render.resolution_y=1500;scene.render.resolution_percentage=100
cd=bpy.data.cameras.new('Cabling QA');cam=bpy.data.objects.new('Cabling QA',cd);scene.collection.objects.link(cam);scene.camera=cam;cd.type='ORTHO'
for name,pos,target,scale in [('cabling-front',(-2.2,-4.6,2.7),(0,-.10,1.14),2.70),('cabling-patch',(-1,-2.5,2.40),(0,-.39,1.985),.74),('cabling-port',(-.65,-1.2,.52),(-.16,-.425,.40),.43)]:
 cam.location=pos;cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler();cd.ortho_scale=scale;scene.render.filepath=str(BASE/'logs'/f'{name}.png');bpy.ops.render.render(write_still=True)
print('CABLING_VALIDATION',json.dumps(report))
