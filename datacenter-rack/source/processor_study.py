"""Selectable POWER9 teaching model, in metres; authored geometry is labelled.

This is a separate explanatory study, never a replacement for source processor CAD.
Call build_processor_study(collection,parent=None), then set_exploded(root,0..1).
No scene reset, render, network access or import-time scene mutation.
"""
from pathlib import Path
import json
import math
import re
import bpy

PREFIX='POWER9 study | '
DATASHEET='research/components/originals/power9-lagrange-v1.7.pdf'
ARCHITECTURE='research/components/originals/power9-hotchips2016.pdf'
PACKAGE_M=.0685
DIE_AREA_MM2=695.0

def _material(name,color,metal=0.0,rough=.4):
    mat=bpy.data.materials.get(PREFIX+name) or bpy.data.materials.new(PREFIX+name)
    mat.diffuse_color=(*color,1);mat.use_nodes=True
    bsdf=mat.node_tree.nodes.get('Principled BSDF');bsdf.inputs['Base Color'].default_value=(*color,1)
    bsdf.inputs['Metallic'].default_value=metal;bsdf.inputs['Roughness'].default_value=rough
    return mat

def _properties(obj,part,function,evidence='Explanatory geometry; dimensions and placement schematic.',source=DATASHEET+' p77'):
    obj['part_id']='processor.study.'+part+'.'+re.sub(r'[^a-z0-9]+','_',obj.name.lower()).strip('_');obj['semantic_type']=part
    obj['function']=function;obj['description']=function;obj['evidence_level']=evidence
    obj['source']=source;obj['geometry_origin']='Authored teaching geometry; not extracted chip CAD'
    return obj

def _empty(col,name,parent=None):
    obj=bpy.data.objects.new(PREFIX+name,None);col.objects.link(obj);obj.parent=parent;obj.empty_display_size=.003
    return obj

def _box(col,name,size,loc,mat,parent):
    sx,sy,sz=[v/2 for v in size]
    vertices=[(x*sx,y*sy,z*sz) for x,y,z in [(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]]
    mesh=bpy.data.meshes.new(PREFIX+name);mesh.from_pydata(vertices,[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]);mesh.update()
    obj=bpy.data.objects.new(PREFIX+name,mesh);col.objects.link(obj);obj.location=loc;obj.parent=parent;mesh.materials.append(mat)
    return obj

def _text(col,name,body,loc,size,mat,parent):
    curve=bpy.data.curves.new(PREFIX+name,'FONT');curve.body=body;curve.size=size;curve.space_line=1.15;curve.align_x='LEFT';curve.extrude=0
    obj=bpy.data.objects.new(PREFIX+name,curve);col.objects.link(obj);obj.parent=parent;obj.location=loc;curve.materials.append(mat);obj['label_for']=parent.name if parent else ''
    return obj

def _explosion(obj,assembled,offset):
    obj['assembled_location_m']=list(assembled);obj['explosion_offset_m']=list(offset);obj.location=assembled

def set_exploded(root,factor=1.0):
    """Deterministic reversible separation; keeps parent-local transforms."""
    factor=max(0.,min(1.,float(factor)));root['exploded_fraction']=factor
    stack=list(root.children)
    while stack:
        obj=stack.pop();stack.extend(obj.children)
        if 'assembled_location_m' in obj:
            a=obj['assembled_location_m'];b=obj['explosion_offset_m'];obj.location=[a[i]+b[i]*factor for i in range(3)]
    return root

def build_processor_study(col,parent=None):
    """Build at parent-local origin; return (root_object, JSON-serializable metadata)."""
    root=_empty(col,'POWER9 LaGrange · package study',parent);root['assembly']=True
    _properties(root,'assembly','Explore the signal path from socket lands through package wiring into cores, caches and I/O; explore the heat path from die through interface and spreader.',
      '68.5 mm square body, 695 mm² die area, 3899 contacts and 7-2-7 construction are documented. Other geometry is schematic.',DATASHEET+' pp19,77; '+ARCHITECTURE+' p4')
    root['component_key']='processor::ibm::power9-lagrange';root['package_body_mm']=68.5;root['documented_land_count']=3899;root['documented_land_pitch_mm']=1.016;root['land_positions_are_exact']=False
    green=_material('organic substrate',(.018,.16,.085));gold=_material('contact symbols',(.68,.36,.07),.78,.26)
    copper=_material('routing symbol',(.52,.16,.045),.8,.32);dark=_material('silicon',(.022,.027,.036),.35,.24)
    grey=_material('spreader',(.48,.53,.57),.88,.28);tim=_material('thermal interface',(.14,.16,.18),.1,.75)
    white=_material('labels',(.85,.9,.95),0,.6);coremat=_material('cores',(.045,.31,.66),.2,.35)
    cachemat=_material('cache',(.035,.52,.39),.2,.4);iomat=_material('I/O',(.65,.29,.055),.15,.4)
    fabricmat=_material('interconnect',(.39,.15,.58),.2,.4)
    contacts=_empty(col,'Land interface · contact symbols',root);contacts['assembly']=True
    _properties(contacts,'land_interface','3899 documented package contacts carry power, ground and signals into the LGA socket. Only144 symbolic contacts are drawn; these are not a physical land map.',
      'Count 3899 and 1.016 mm hexagonal pitch documented; this 144 symbol grid is deliberately schematic.',DATASHEET+' p77; pin-list pp79–116')
    _explosion(contacts,(0,0,-.00012),(0,0,-.013))
    _box(col,'Land-side substrate backing',(PACKAGE_M,PACKAGE_M,.00015),(0,0,0),green,contacts)
    # Small shared round symbol mesh: this is explicitly not the 3899-position package land map.
    verts=[];segments=12
    for z in [-.00011,.00011]:
        for i in range(segments):
            a=math.tau*i/segments;verts.append((.00115*math.cos(a),.00115*math.sin(a),z))
    faces=[tuple(reversed(range(segments))),tuple(range(segments,2*segments))]+[(i,(i+1)%segments,(i+1)%segments+segments,i+segments) for i in range(segments)]
    mesh=bpy.data.meshes.new(PREFIX+'shared contact symbol');mesh.from_pydata(verts,[],faces);mesh.materials.append(gold)
    for iy in range(12):
        for ix in range(12):
            obj=bpy.data.objects.new(PREFIX+f'contact symbol {iy*12+ix+1:03d}',mesh);col.objects.link(obj);obj.parent=contacts;obj.location=((ix-5.5)*.0048,(iy-5.5)*.0048,.00015)
            _properties(obj,'contact_symbol', 'Illustrative LGA contact symbol; no pin number or exact signal assignment.', 'Symbolic position; 144 shown of 3899 documented contacts.')
    _text(col,'Land interface caption','LAND INTERFACE — SYMBOLS ONLY\n3899 contacts documented; positions not reconstructed',(-.033,-.039,.0002),.002,white,contacts)
    layers=[]
    for i in range(16):
        group='bottom build-up' if i<7 else ('core' if i<9 else 'top build-up')
        obj=_box(col,f'Substrate {i+1:02d} · {group}',(PACKAGE_M,PACKAGE_M,.000085),(0,0,(i+.5)*.000095),green if i%2 else copper,root)
        _properties(obj,'substrate_layer',f'Organic package construction 7-2-7: this is diagram band {i+1} of 16. Wiring distributes signals and power between a dense die interface and socket lands.',
          '7-2-7 construction documented; individual band thickness, colors, routing and material assignment are schematic.')
        _explosion(obj,(0,0,(i+.5)*.000095),(0,0,(i/15)*.019));layers.append(obj)
    _text(col,'Substrate caption','ORGANIC SUBSTRATE · 7—2—7\n16 diagram bands; thickness and routing schematic',(-.033,-.039,.0001),.002,white,layers[8])
    die_side=math.sqrt(DIE_AREA_MM2)*.001
    die=_box(col,'Silicon die · functional study',(die_side,die_side,.0005),(0,0,.0018),dark,root)
    die['assembly']=True;die['documented_die_area_mm2']=695
    _properties(die,'silicon_die','The transistor circuitry executes instructions and controls memory and I/O. The functional tiles show architecture, not transistor placement.',
      '695 mm² die area documented; square aspect ratio, thickness, package placement and functional-tile geometry are schematic.',DATASHEET+' p19; '+ARCHITECTURE+' p4')
    _explosion(die,(0,0,.0018),(0,0,.036))
    _text(col,'Die caption','SILICON · FUNCTIONAL DIAGRAM\n695 mm² documented; tile placement schematic',(-.033,-.020,.0004),.0018,white,die)
    # Twelve paired-core regions, each with separate L2 and L3 teaching tiles.
    for region in range(12):
        side=-1 if region<6 else 1;row=region%6;x=side*.0071;y=(row-2.5)*.0033
        for within in range(2):
            number=region*2+within+1;obj=_box(col,f'Core {number:02d}',(.0026,.00115,.0004),(x+(within-.5)*.00285,y+.00075,.0005),coremat,die)
            _properties(obj,'core',f'Core {number}: executes instruction streams. The teaching diagram shows maximum 24-core SMT4 capability, not the enabled configuration of this rack.', '24-core capability documented; tile geometry schematic.',DATASHEET+' p11; '+ARCHITECTURE+' pp4–5')
            _text(col,f'Core {number:02d} label',f'C{number:02d}',(-.0011,-.00035,.00021),.00063,white,obj)
        l2=_box(col,f'L2 region {region+1:02d}',(.0054,.00055,.0003),(x,y-.00018,.00048),cachemat,die)
        _properties(l2,'L2_cache','L2 cache holds recently used instructions and data close to the cores.', 'Cache relationship from IBM architecture diagram; placement schematic.',ARCHITECTURE+' p4')
        l3=_box(col,f'L3 region {region+1:02d}',(.0054,.0008,.00035),(x,y-.001,.0005),cachemat,die)
        _properties(l3,'L3_cache','One of 12 L3 regions in the 120 MB NUCA cache architecture. Cache hits avoid slower off-chip memory access.', '12 regions / 120 MB architecture documented; tile geometry schematic.',ARCHITECTURE+' p4')
    fabric=_box(col,'On-chip interconnect',(.0022,.023,.0004),(0,0,.0005),fabricmat,die)
    _properties(fabric,'interconnect','Moves requests and data among cores, cache regions, memory and I/O controllers.', 'Architectural connection role documented; geometry schematic.',ARCHITECTURE+' p4')
    io_specs=[('DDR4 memory controllers',(.021,.0013,.0005),(0,.012,.00055),'Eight DDR4 interfaces connect the processor to DIMMs.'),('PCIe Gen4 I/O',(.010,.0013,.0005),(-.0057,-.012,.00055),'LaGrange exposes42 PCIe Gen4 lanes, grouped as two x16, one x8 and one x2.'),('25G / SMP links',(.010,.0013,.0005),(.0057,-.012,.00055),'Two 25G link bricks and two X-bus links connect accelerator and processor peers.')]
    for name,size,loc,function in io_specs:
        obj=_box(col,name,size,loc,iomat,die);_properties(obj,'IO_controller',function,'Interface counts documented; tile placement schematic.',DATASHEET+' p77')
    thermal=_box(col,'Thermal interface · schematic',(die_side*.98,die_side*.98,.0002),(0,0,.0022),tim,root)
    _properties(thermal,'thermal_interface','An illustrative interface fills microscopic gaps to conduct heat away from silicon toward the spreader.', 'Generic packaging explanation. LaGrange interface material and thickness not acquired.')
    _explosion(thermal,(0,0,.0022),(0,0,.052))
    spreader=_box(col,'Heat spreader · schematic',(.054,.054,.002),(0,0,.0035),grey,root)
    _properties(spreader,'heat_spreader','An illustrative heat spreader spreads heat over a larger area before the external heatsink removes it.', 'Generic explanatory shape/material; exact LaGrange spreader drawing, plating and dimensions not acquired.')
    _explosion(spreader,(0,0,.0035),(0,0,.069))
    _text(col,'Heat path caption','HEAT PATH\nDie → interface → spreader → external heatsink',(-.033,-.039,.0011),.002,white,spreader)
    root['exploded_fraction']=0.0
    metadata={'schema':'power9-processor-study/v1','root_object':root.name,'units':'meters','package_body_xy_mm':[68.5,68.5],'die_area_mm2':695,'die_aspect_ratio':'square schematic; area preserved','documented_contacts':3899,'drawn_contact_symbols':144,'exact_land_map':False,'substrate_construction':'7-2-7 organic; 16 schematic bands','drawn_cores':24,'enabled_core_count':'unspecified','study_is_source_CAD':False,'explosion_api':'set_exploded(root,factor), factor 0 assembled / 1 separated','sources':[{'path':DATASHEET,'pages':[11,19,77,79]},{'path':ARCHITECTURE,'pages':[4,5]}],'limitations':['Land coordinates and assigned signals are not reconstructed.','Thicknesses, heat spreader geometry, die aspect ratio, internal tile coordinates and colors are explanatory.','The 17 metal layers in CMOS technology are distinct from the package 7-2-7 construction; no transistor or metal-routing layout is depicted.','This model does not assert the installed rack processor ordering code, stepping or enabled core count.']}
    root['study_metadata_json']=json.dumps(metadata);return root,metadata
