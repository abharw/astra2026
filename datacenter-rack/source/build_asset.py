"""Reproducible SI Blender asset from the licensed EVT mechanical/EDA sources.

Source geometry and reconstructed appearance remain separately identified.
Use Blender --background --factory-startup --python this_file -- --preview.
"""
from pathlib import Path
import argparse, json, math, sys, time
import bpy
import numpy as np
from mathutils import Matrix, Vector

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'source'))
from pcb_population import build_pcb_population
from cad_configuration import build_configuration
from rack_frame import build_rack

def collection(name,scene=None,parent=None):
    c=bpy.data.collections.new(name)
    if parent:parent.children.link(c)
    elif scene:scene.collection.children.link(c)
    return c

def material(name,color,metal=0,rough=.4):
    m=bpy.data.materials.new(name);m.diffuse_color=(*color,1);m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*color,1)
    p.inputs['Metallic'].default_value=metal;p.inputs['Roughness'].default_value=rough
    m['evidence_level']='material-class reconstruction; not calibrated reflectance'
    return m

def tag(obj,pid,description,level='reference reconstruction'):
    obj['part_id']=pid;obj['description']=description;obj['evidence_level']=level
    return obj

def box(name,loc,size,mat,col,parent=None,bevel=.0002):
    x,y,z=[v/2 for v in size];me=bpy.data.meshes.new(name)
    me.from_pydata([(-x,-y,-z),(x,-y,-z),(x,y,-z),(-x,y,-z),(-x,-y,z),(x,-y,z),(x,y,z),(-x,y,z)],[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)])
    o=bpy.data.objects.new(name,me);col.objects.link(o);o.location=loc;o.parent=parent;me.materials.append(mat)
    if bevel:
        b=o.modifiers.new('Small manufactured edge','BEVEL');b.width=bevel;b.segments=2
        o.modifiers.new('Weighted normals','WEIGHTED_NORMAL')
    tag(o,name,name);return o

def label(name,text,loc,size,mat,col,rotation=(0,0,0),parent=None):
    d=bpy.data.curves.new(name,'FONT');d.body=text;d.size=size;d.extrude=.000005
    o=bpy.data.objects.new(name,d);col.objects.link(o);o.location=loc;o.rotation_euler=rotation;o.parent=parent;d.materials.append(mat)
    tag(o,name,'Authored identification label; not factory serial or artwork');return o

def board_material(side):
    m=material('EVT3 red OSP PCB / '+side,(.24,.012,.021),.05,.3)
    n=m.node_tree.nodes;l=m.node_tree.links;p=n.get('Principled BSDF')
    tex={}
    for layer in ['copper','mask-openings','silkscreen']:
        a=n.new('ShaderNodeTexImage');a.image=bpy.data.images.load(str(ROOT/f'research/pcb-population/textures/{side}-{layer}.png'),check_existing=True)
        a.image.colorspace_settings.name='Non-Color';a.interpolation='Linear';tex[layer]=a
    mix=n.new('ShaderNodeMixRGB');mix.blend_type='MIX';mix.inputs[1].default_value=(.19,.005,.012,1);mix.inputs[2].default_value=(.45,.25,.095,1)
    l.new(tex['mask-openings'].outputs['Color'],mix.inputs[0])
    silk=n.new('ShaderNodeMixRGB');silk.inputs[2].default_value=(.88,.87,.80,1)
    l.new(mix.outputs[0],silk.inputs[1]);l.new(tex['silkscreen'].outputs['Color'],silk.inputs[0]);l.new(silk.outputs[0],p.inputs['Base Color'])
    metal=n.new('ShaderNodeMapRange');metal.inputs['To Min'].default_value=.08;metal.inputs['To Max'].default_value=.85
    l.new(tex['mask-openings'].outputs['Color'],metal.inputs['Value']);l.new(metal.outputs[0],p.inputs['Metallic'])
    bump=n.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.25;bump.inputs['Distance'].default_value=.000025
    l.new(tex['copper'].outputs['Color'],bump.inputs['Height']);l.new(bump.outputs[0],p.inputs['Normal'])
    m['source']='Actual EVT3 Gerber copper / solder-mask openings / silkscreen';m['substrate']='BOM red OSP 22-layer motherboard'
    return m

def apply_board_surface(obj):
    mesh=obj.data;mesh.materials.clear()
    for m in [board_material('top'),board_material('bottom'),material('PCB cut edges',(.20,.11,.065),0,.6)]:mesh.materials.append(m)
    uv=mesh.uv_layers.new(name='Fabrication coordinates')
    world=obj.matrix_world.copy()
    for poly in mesh.polygons:
        normal=world.to_3x3()@poly.normal
        poly.material_index=0 if normal.z>.5 else 1 if normal.z<-.5 else 2
        for li in poly.loop_indices:
            v=world@mesh.vertices[mesh.loops[li].vertex_index].co
            uv.data[li].uv=((v.x+.228)/.3302,(v.y-.00313)/.56388)

def apply_cad_repairs(objects,index):
    repaired=[]
    by_label={d['label']:d for d in index['definitions']}
    done=set()
    for o in objects.values():
        if o.type!='MESH' or o.data.name in done:continue
        d=by_label[o['cad_definition_id']];path=ROOT/f'research/cad-diagnostics/repaired-meshes/{d["id"]}.npz'
        done.add(o.data.name)
        if not path.exists():continue
        a=np.load(path);v=a['vertices'];f=a['triangles'];m=o.data
        m.clear_geometry();m.vertices.add(len(v));m.vertices.foreach_set('co',v.reshape(-1))
        m.loops.add(f.size);m.loops.foreach_set('vertex_index',f.reshape(-1));m.polygons.add(len(f))
        m.polygons.foreach_set('loop_start',np.arange(0,f.size,3,dtype=np.int32));m.polygons.foreach_set('loop_total',np.full(len(f),3,dtype=np.int32))
        m.polygons.foreach_set('use_smooth',np.ones(len(f),dtype=bool));m.update()
        m['repair_evidence']='Finer tessellation of unchanged original source faces; source geometry bounds unchanged';repaired.append(d['id'])
    print('CAD_SURFACE_REPAIRS',repaired,flush=True);return repaired

def new_scene(name):
    s=bpy.data.scenes.new(name);s.unit_settings.system='METRIC';s.unit_settings.scale_length=1
    return s

def instance(name,col,loc,target):
    o=bpy.data.objects.new(name,None);o.instance_type='COLLECTION';o.instance_collection=col;o.location=loc;target.objects.link(o)
    o.empty_display_type='CUBE';o.empty_display_size=.04;return o

def studio(scene,position,target,scale,res=(1800,1400),floor=-.008):
    c=collection(scene.name+' / studio',scene)
    cam=bpy.data.cameras.new(scene.name+' camera');o=bpy.data.objects.new(cam.name,cam);c.objects.link(o)
    o.location=position;o.rotation_euler=(Vector(target)-o.location).to_track_quat('-Z','Y').to_euler()
    cam.type='ORTHO';cam.ortho_scale=scale;cam.clip_start=.0001;cam.clip_end=100;scene.camera=o
    for name,delta,power,size,color in [('Key',(-1.0,-.8,1.8),450,1.4,(.84,.91,1)),('Soft fill',(1.2,-.1,1.0),300,1.1,(1,.87,.71)),('Rim',(.2,1.3,1.6),650,1,(.66,.8,1))]:
        d=bpy.data.lights.new(scene.name+' '+name,'AREA');d.energy=power*scale*scale;d.shape='DISK';d.size=size*scale;d.color=color
        ob=bpy.data.objects.new(d.name,d);c.objects.link(ob);ob.location=Vector(target)+Vector(delta)*scale;ob.rotation_euler=(Vector(target)-ob.location).to_track_quat('-Z','Y').to_euler()
    scene.world=bpy.data.worlds.new(scene.name+' world');scene.world.use_nodes=True;scene.world.node_tree.nodes['Background'].inputs[0].default_value=(.11,.14,.19,1);scene.world.node_tree.nodes['Background'].inputs[1].default_value=.25
    ground=box(scene.name+' floor',(0,0,floor-.008),(200,200,.016),material(scene.name+' floor matte',(.023,.030,.043),.12,.36),c,bevel=0)
    for ob in c.objects:
        ob.hide_select=True
        if 'part_id' in ob:del ob['part_id']
    scene.render.engine='CYCLES';scene.cycles.samples=48;scene.cycles.use_denoising=True
    prefs=bpy.context.preferences.addons['cycles'].preferences
    try:
        prefs.compute_device_type='METAL';prefs.get_devices()
        for device in prefs.devices:device.use=device.type=='METAL'
        if any(d.use for d in prefs.devices):scene.cycles.device='GPU'
    except (TypeError,RuntimeError):pass
    scene.render.resolution_x=res[0];scene.render.resolution_y=res[1];scene.render.resolution_percentage=100
    scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA'
    scene.view_settings.view_transform='AgX';scene.render.film_transparent=False
    scene['studio_note']='Presentation lights and floor are in a separate collection; exclude for AR asset export.'
    return c

def create_ram(config,col,mats):
    """DDR4 RDIMM class analogue. Factory SKU is deliberately not asserted."""
    out=[]
    for k,slot in enumerate(config.get('ram_slots',[])):
        # Config supplies published clearance-model center; board geometry is authored.
        mat=slot['matrix_world_m'];x,y,z=mat[0][3],-mat[2][3],mat[1][3]
        pid=f'server.memory.module.{k+1:02d}'
        root=bpy.data.objects.new(pid,None);col.objects.link(root);root.location=(x,y,z)
        root.rotation_euler.z=math.atan2(-mat[2][0],mat[0][0])-math.pi/2
        root['socket_refdes']=slot['socket_refdes']
        tag(root,pid,'DDR4 RDIMM 133.35 x31.25mm, 36-package supported-class analogue; installed SKU unspecified')
        root['manufacturer']='Class analogue based on Kingston drawing';root['source_url']='https://www.kingston.com/datasheets/KVR24R17D4_32.pdf';root['geometry_status']='reconstructed class analogue in source socket position'
        # Board plane YZ; clear asymmetric key breaks the lower gold-contact edge.
        length=.13335;height=.03125
        key=.07225-length/2
        profile=[(-length/2,0),(key-.00075,0),(key-.00075,.0025),(key+.00075,.0025),(key+.00075,0),(length/2,0),(length/2,.016),(length/2-.0015,.016),(length/2-.0015,.019),(length/2,.019),(length/2,height),(-length/2,height),(-length/2,.019),(-length/2+.0015,.019),(-length/2+.0015,.016),(-length/2,.016)]
        me=bpy.data.meshes.new(pid+'.keyed PCB');nv=len(profile)
        me.from_pydata([(xx,yy,zz) for xx in [-.000635,.000635] for yy,zz in profile],[],[tuple(reversed(range(nv))),tuple(range(nv,2*nv))]+[(i,(i+1)%nv,(i+1)%nv+nv,i+nv) for i in range(nv)])
        board=bpy.data.objects.new(pid+'.pcb',me);col.objects.link(board);board.parent=root;me.materials.append(mats['ram']);tag(board,pid+'.pcb','Keyed DDR4 outline and end latch notches, reconstructed from public dimensioned drawing')
        board['model']='DDR4 288-contact RDIMM class; exact fitted module unknown'
        # Individual contacts are visible on both faces. Edge notches are not hidden by a texture.
        for side in [-1,1]:
            for i in range(144):
                yy=-length/2+.004+i*(length-.008)/143
                if abs(yy-key)<.0009:continue
                box(pid+f'.contact.{side}.{i:03d}',(side*.000655,yy,.0026),(.00004,.00042,.0048),mats['gold'],col,root,0)
            for row in range(2):
                for j in range(9):
                    part=box(pid+f'.dram.{side}.{row}.{j}',(side*.00135,-.055+j*.01375,.010+row*.011),(.0014,.0105,.008),mats['ic'],col,root,.00012)
                    part['description']='DRAM package on class-analogue RDIMM; precise die/MPN unspecified'
        label(pid+'.mark','DDR4  •  RDIMM\nCLASS ANALOGUE',(.0021,-.024,.014),.0024,mats['white'],col,(math.pi/2,0,math.pi/2),root)
        out.append(root)
    return out

def build(args):
    started=time.monotonic();idx=json.loads((ROOT/'models/barreleye-evt-mesh/assembly.json').read_text());report=json.loads((ROOT/'models/barreleye-source-v001.json').read_text())
    config=build_configuration(idx,report)
    (ROOT/'models/configuration-receipt.json').write_text(json.dumps(config,indent=2))
    bpy.ops.wm.open_mainfile(filepath=str(ROOT/'models/barreleye-source-v001.blend'))
    scene=bpy.context.scene;scene.name='02 · Open server'
    objects={o['part_id'].removeprefix('server.cad.'):o for o in scene.objects if str(o.get('part_id','')).startswith('server.cad.')}
    keep=set(config['keep_node_ids']);lids=set(config.get('lid_node_ids',[]))
    doomed=[obj for key,obj in objects.items() if key not in keep]+[o for o in scene.objects if not o.get('part_id')]
    bpy.data.batch_remove(ids=doomed)
    objects={key:obj for key,obj in objects.items() if key in keep}
    print('CONFIGURATION_SELECTED',len(objects),flush=True)
    repairs=apply_cad_repairs(objects,idx)
    master=collection('SERVER · fully editable source assembly',scene);lidcol=collection('SERVER · removable cover')
    for obj in objects.values():
        for c in list(obj.users_collection):c.objects.unlink(obj)
        (lidcol if obj.get('part_id','').removeprefix('server.cad.') in lids else master).objects.link(obj)
    for c in list(scene.collection.children):
        if c!=master:scene.collection.children.unlink(c)
    for o in objects.values():
        if o.parent is None:o.rotation_euler.x+=math.pi/2
    bpy.context.view_layer.update()
    mats={
      'metal':material('Brushed zinc steel',(.42,.47,.52),.87,.32),
      'black':material('Black engineering polymer',(.013,.018,.023),.03,.34),
      'blue':material('Blue memory socket',(.014,.080,.27),.04,.32),
      'ic':material('Molded semiconductor package',(.014,.017,.022),.05,.4),
      'gold':material('Contact gold',(.55,.32,.065),.92,.23),
      'copper':material('C1100 copper thermal assembly',(.52,.22,.105),.96,.27),
      'pcb':material('Auxiliary PCB solder mask',(.025,.17,.11),.15,.34),
      'ram':material('RDIMM green substrate',(.013,.09,.035),.08,.3),
      'white':material('Identification white',(.82,.87,.88),0,.5),
    }
    population_source=json.loads((ROOT/'research/pcb-population/population-source.json').read_text())
    by_ref={v['refdes']:v for v in population_source['components']}
    # Preserve source topology; names and hierarchy establish material-class mapping.
    assignment={}
    processed_meshes=set()
    thermal_rows=json.loads((ROOT/'research/cad-diagnostics/cpu-material-map.json').read_text())['rows']
    copper_labels={r['definition_label'] for r in thermal_rows if 'copper' in r['suggested_material'].lower()}
    for key,o in objects.items():
        ref=config.get('refdes_by_node',{}).get(key)
        if ref:
            o['refdes']=ref
            source=by_ref.get(ref,{})
            bom=(source.get('bom_candidates') or [{}])[0]
            o['manufacturer']=bom.get('manufacturer','');o['manufacturer_part_number']=bom.get('manufacturer_part','')
            o['description']=bom.get('description',o.get('description',''))
        if o.type!='MESH':continue
        names=[];p=o
        while p:names.append(p.get('cad_name',p.name));p=p.parent
        name=o.get('cad_name','').upper();ancestry=' / '.join(names).upper();mat=mats['metal']
        if any(v in name for v in ['PCB','PCBA','DDR4_DAISY']):mat=mats['pcb']
        if any(v in name for v in ['HOUSING','SOCKET','CONNECTOR','MYLAR','RUBBER','PLUG','INSUL','FAN-BODY','FAN_BODY','FAN60','CABLE','DDR4_SMT']):mat=mats['black']
        if 'CONTACT' in name:mat=mats['gold']
        if ref and ',BLU,' in o.get('description',''):mat=mats['blue']
        if 'HS855600' in ancestry:mat=mats['copper'] if any(v in name for v in ['CU-BLOCK','PIPE','MANIFOLD_SOLID']) else mats['metal']
        if o.get('cad_definition_id') in copper_labels:mat=mats['copper']
        if key in ['node-00986','node-01165']:mat=mats['pcb']
        if key in ['node-00987','node-01166']:mat=mats['metal']
        if o.data.name not in processed_meshes:
            o.data.materials.clear();o.data.materials.append(mats['metal'])
            o.data.polygons.foreach_set('material_index',np.zeros(len(o.data.polygons),dtype=np.int32));processed_meshes.add(o.data.name)
        o.material_slots[0].link='OBJECT';o.material_slots[0].material=mat
        o['appearance_evidence']='Source name/material-class reconstruction';assignment[key]=mat.name
        ref=config.get('refdes_by_node',{}).get(key)
        if ref:o['refdes']=ref
    board=objects['node-00773'];apply_board_surface(board)
    board.material_slots[0].link='DATA'
    print('CAD_MATERIALS_READY',flush=True)
    align=bpy.data.objects.new('Motherboard fabrication alignment',None);master.objects.link(align);align.location=(-.228,.00313,.0105)
    tag(align,'server.motherboard.population','EVT3 source placements registered to published motherboard CAD','source-derived registration')
    pop=build_pcb_population(parent=align,skip_refdes=set(config['skip_refdes']))
    for o in [pop['root']]+pop['objects']:
        for c in list(o.users_collection):c.objects.unlink(o)
        master.objects.link(o)
    ram=create_ram(config,master,mats)
    print('PCB_AND_RAM_READY',len(pop['objects']),len(ram),flush=True)
    # Metadata text is embedded without execution: inspect or run the separate add-on explicitly.
    for path in [ROOT/'source/rack_inspector.py',ROOT/'docs/COMPONENT_GUIDE.md',ROOT/'docs/INSPECTION_CONTROLS.md']:
        bpy.data.texts.load(str(path))
    bpy.data.texts.new('READ ME · asset status').write('Open Rack V2 / Barreleye G2 EVT. Units: metres.\n02 Open server is the editable master. 01 Rack uses linked collection instances.\nEvery source-derived part retains provenance. Material finish and explicitly labeled analogue modules are reconstructed.\nNo physical robot interaction or electrical simulation has been validated.\nRun rack_inspector.py to enable N-sidebar Rack Lab controls.\n')
    closed=collection('SERVER · closed rack instance');closed.children.link(master);closed.children.link(lidcol)
    studio(scene,(1.0,-.82,1.12),(0,.40,.03),1.13,(1900,1500))
    rackscene=new_scene('01 · Full rack');bpy.context.window.scene=rackscene
    rack=build_rack();servers=collection('Installed server instances',rackscene)
    print('RACK_READY',flush=True)
    for i,ou in enumerate(range(1,36,2)):
        loc=rack['server_slot_origins'][ou]
        o=instance(f'rack.server.{i+1:02d} · Barreleye G2',closed,loc,servers)
        tag(o,f'rack.server.{i+1:02d}','Linked Barreleye G2 EVT training server. Inspect the master in scene 02.','source-derived assembly with reconstructed rack integration')
        o['service_scene']=scene.name;o['service_direction']='-Y';o['source_revision']='EVT3'
    try:
        from rack_cabling import build_cabling
        build_cabling(rack['server_slot_origins'],parent=rack['root'])
    except ImportError:print('Cabling module pending; preview only',flush=True)
    studio(rackscene,(3.3,-4.5,3.0),(0,.05,1.12),3.2,(1600,2000),floor=0)
    # Board-only study reuses the exact objects with a filtered collection instance.
    boardcol=collection('Motherboard study · selected geometry')
    boardcol.objects.link(board)
    for key,o in objects.items():
        p=o.parent;is_board=False
        while p:
            if p.get('part_id')=='server.cad.node-00771':is_board=True;break
            p=p.parent
        if is_board and o!=board:boardcol.objects.link(o)
    for o in [align,pop['root']]+pop['objects']:boardcol.objects.link(o)
    boardscene=new_scene('03 · Motherboard fabrication');boardscene.collection.children.link(boardcol)
    studio(boardscene,(.56,-.3,.85),(-.063,.285,.018),.70,(1600,1900),floor=-.015)
    bpy.context.window.scene=scene
    for area in bpy.context.screen.areas:
        if area.type=='VIEW_3D':
            area.spaces.active.clip_start=.0001;area.spaces.active.clip_end=100
            area.spaces.active.region_3d.view_location=(0,.4,.025);area.spaces.active.region_3d.view_distance=1.2
            area.spaces.active.shading.type='SOLID';area.spaces.active.shading.color_type='MATERIAL'
            area.spaces.active.overlay.show_relationship_lines=False;area.spaces.active.overlay.show_extras=False;area.spaces.active.overlay.show_floor=False
    for o in scene.objects:o.select_set(False)
    bpy.context.view_layer.objects.active=None
    # Archive current build receipt; rendered beauty still needs visual acceptance.
    receipt={'schema':'rack-asset-build/v1','blender':bpy.app.version_string,'cad_kept':len(objects),'pcb':pop['metadata']['receipt'],'ram_modules':len(ram),'rack_slots':rack['server_slot_origins'],'objects':len(bpy.data.objects),'unique_meshes':len(bpy.data.meshes),'seconds':time.monotonic()-started,'material_assignments':assignment,'status':'built; render review pending'}
    (ROOT/'models/asset-build-receipt.json').write_text(json.dumps(receipt,indent=2))
    # Purge orphaned source variants only from this derivative file.
    bpy.data.orphans_purge(do_recursive=True)
    for im in bpy.data.images:
        if im.source=='FILE' and im.has_data:im.pack()
    dest=ROOT/'models/datacenter-rack-v001.blend';bpy.ops.wm.save_as_mainfile(filepath=str(dest),compress=True)
    print('ASSET_SAVED',str(dest),len(bpy.data.objects),flush=True)
    if args.preview:
        scene.cycles.samples=24;scene.render.resolution_percentage=65;scene.render.filepath=str(ROOT/'renders/server-preview.png')
        bpy.ops.render.render(write_still=True,scene=scene.name)
    print('ASSET_BUILD_COMPLETE',json.dumps({k:v for k,v in receipt.items() if k not in ['material_assignments','pcb']}),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--preview',action='store_true');a=p.parse_args(sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else [])
    (ROOT/'renders').mkdir(exist_ok=True);build(a)
