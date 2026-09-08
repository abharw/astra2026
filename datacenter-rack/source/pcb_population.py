"""Source-driven Zaius EVT3 PCB population for Blender.

No scene/world transform is assumed. ODB XY is converted to meters; top surface
is Z=0 and bottom surface is Z=-0.003 m (published 3.00 +/-0.30 mm board).
Every physical object corresponds to a PWA-BOM-listed reference designator.
Package outlines and pad shapes come from ODB EDA; extrusion, small edge bevels,
terminal thickness and material appearance are reconstructed, not manufacturer
mechanical geometry. The supplied STEP should replace major devices via
``skip_refdes`` when that CAD instance is already present.

Usage inside Blender::
    result = build_pcb_population(parent=pcb_alignment_empty,
                                  skip_refdes={'U1', 'U10'})

The caller owns alignment, lighting, material tuning, and duplicate matching.
"""
from __future__ import annotations

import collections
import hashlib
import json
import math
from pathlib import Path
import time

import bpy
from mathutils import Matrix

PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = PROJECT / 'research/pcb-population/population-source.json'
MM = 0.001
INCH_MM = 25.4

# Appearance is deliberately separate from exact source placement/outline data.
MATERIALS = {
    'resistor': ('Resistor body', (0.028, 0.031, 0.035, 1), 0.0, 0.39),
    'ceramic': ('Ceramic capacitor body', (0.38, 0.23, 0.115, 1), 0.0, 0.37),
    'polymer_capacitor': ('Polymer capacitor body', (0.11, 0.095, 0.08, 1), 0.0, 0.36),
    'integrated_circuit': ('Molded IC body', (0.021, 0.025, 0.028, 1), 0.0, 0.46),
    'connector': ('Connector housing', (0.046, 0.049, 0.052, 1), 0.0, 0.38),
    'connector_blue': ('Blue DIMM socket housing', (0.024, 0.12, 0.34, 1), 0.0, 0.34),
    'magnetic': ('Ferrite magnetic body', (0.074, 0.079, 0.085, 1), 0.0, 0.52),
    'discrete_semiconductor': ('Discrete semiconductor body', (0.026, 0.030, 0.035, 1), 0.0, 0.40),
    'led': ('LED package body', (0.28, 0.33, 0.19, 1), 0.0, 0.29),
    'fuse': ('Fuse body', (0.48, 0.45, 0.36, 1), 0.0, 0.48),
    'timing': ('Timing device case', (0.47, 0.50, 0.52, 1), 0.72, 0.29),
    'converter': ('Converter module body', (0.080, 0.085, 0.09, 1), 0.25, 0.35),
    'other': ('Source package body', (0.08, 0.085, 0.09, 1), 0.0, 0.44),
    'terminal': ('Tin plated terminal reconstruction', (0.56, 0.59, 0.61, 1), 0.93, 0.23),
    'depop': ('Unpopulated pad reconstruction', (0.53, 0.37, 0.12, 1), 0.90, 0.29),
}

FUNCTIONS = {
    'resistor': 'Provides electrical resistance; exact circuit role is in the schematic.',
    'ceramic': 'Stores electrical charge; the connected circuit determines filtering or other use.',
    'polymer_capacitor': 'Stores electrical charge in the documented capacitor technology.',
    'integrated_circuit': 'Integrated electronic function identified by the sourced manufacturer part number.',
    'connector': 'Provides the documented electrical connection to another part or cable.',
    'connector_blue': 'Receives a 288-contact DDR4 memory module.',
    'magnetic': 'Provides inductance or ferrite impedance as identified in the BOM.',
    'discrete_semiconductor': 'Discrete semiconductor function identified by the BOM device type.',
    'led': 'Light-emitting diode; indicator state and emission color are not inferred.',
    'fuse': 'Fuse or fuse contact; protects or connects the documented power circuit.',
    'timing': 'Crystal or oscillator used as a timing element.',
    'converter': 'Converts or regulates electrical power as identified by its manufacturer part.',
    'other': 'Function remains the sourced BOM description; no role inferred from position.',
}


def _material(category):
    label, color, metallic, roughness = MATERIALS[category]
    name = 'PCB EVT3 / ' + label
    material = bpy.data.materials.get(name)
    if material is None:
        material = bpy.data.materials.new(name)
        material.use_nodes = True
        material.diffuse_color = color
        bsdf = material.node_tree.nodes.get('Principled BSDF')
        bsdf.inputs['Base Color'].default_value = color
        bsdf.inputs['Metallic'].default_value = metallic
        bsdf.inputs['Roughness'].default_value = roughness
        material['appearance_evidence'] = 'inferred material class; root may replace from manufacturer evidence'
    return material


def _category(component):
    bom = component.get('bom_candidates') or [{}]
    description = bom[0].get('description', '').upper()
    if 'DDR IV' in description and ',BLU,' in description:
        return 'connector_blue'
    if description.startswith(('CONN', 'POWER9 CPU SOCKET')):
        return 'connector'
    if description.startswith(('RES,', 'RES ')):
        return 'resistor'
    if description.startswith('CAP,'):
        return 'ceramic'
    if description.startswith(('ECAP', 'SP-CAP', 'SPEA', 'SPET', 'SPEA CAP')):
        return 'polymer_capacitor'
    if description.startswith(('IC,', 'LOGIC IC', 'DRAM', 'FLASH', 'EEPROM')):
        return 'integrated_circuit'
    if description.startswith(('IND,', 'FB,', 'COMMON CHOKE', 'FILTER')):
        return 'magnetic'
    if description.startswith(('MOS ', 'TRANS ', 'DIODE', 'TVS DIODE')):
        return 'discrete_semiconductor'
    if description.startswith('LED'):
        return 'led'
    if description.startswith('FUSE'):
        return 'fuse'
    if description.startswith(('XTAL', 'OSC')):
        return 'timing'
    if description.startswith('CONVERTER'):
        return 'converter'
    return 'other'


def _area(points):
    return sum(a[0]*b[1]-b[0]*a[1] for a,b in zip(points, points[1:]+points[:1])) / 2


def _outline_loops(records, circle_segments=20):
    """Read original ODB RC/CR/contour records; approximate arcs only by chords."""
    loops=[]; current=[]
    def finish():
        nonlocal current
        if len(current)>1 and math.dist(current[0], current[-1])<1e-8:
            current.pop()
        if len(current)>=3:
            if _area(current)<0: current.reverse()
            loops.append(current)
        current=[]
    for record in records:
        fields=record.split(); op=fields[0]
        if op=='RC':
            finish(); x,y,w,h=[float(x)*INCH_MM for x in fields[1:5]]
            current=[(x,y),(x+w,y),(x+w,y+h),(x,y+h)]; finish()
        elif op=='CR':
            finish(); x,y,r=[float(x)*INCH_MM for x in fields[1:4]]
            current=[(x+r*math.cos(a*math.tau/circle_segments),y+r*math.sin(a*math.tau/circle_segments)) for a in range(circle_segments)]; finish()
        elif op=='OB':
            finish(); current=[(float(fields[1])*INCH_MM,float(fields[2])*INCH_MM)]
        elif op=='OS':
            current.append((float(fields[1])*INCH_MM,float(fields[2])*INCH_MM))
        elif op=='OC' and current:
            ex,ey,cx,cy=[float(x)*INCH_MM for x in fields[1:5]]
            sx,sy=current[-1]; start=math.atan2(sy-cy,sx-cx); end=math.atan2(ey-cy,ex-cx)
            clockwise=fields[5]=='Y'
            sweep=-((start-end)%math.tau) if clockwise else (end-start)%math.tau
            radius=math.hypot(sx-cx,sy-cy)
            # At least four segments per quarter-circle, <=0.02mm chord error.
            step=2*math.acos(max(-1,min(1,1-0.02/max(radius,0.02))))
            count=max(1,math.ceil(abs(sweep)/min(math.pi/8,step)))
            for k in range(1,count+1):
                t=start+sweep*k/count; current.append((cx+radius*math.cos(t),cy+radius*math.sin(t)))
            current[-1]=(ex,ey)
        elif op=='OE': finish()
    finish()
    return loops


def _prism(vertices, faces, material_ids, loop, z0, z1, material_id, bevel=0):
    if len(loop)<3 or z1<=z0: return
    rings=[(loop,z0)]
    if bevel>0 and z1-z0>bevel*2:
        cx=sum(x for x,y in loop)/len(loop);cy=sum(y for x,y in loop)/len(loop)
        # Inward top chamfer is an explicitly inferred finish, preserving envelope.
        span=max(max(x for x,y in loop)-min(x for x,y in loop),max(y for x,y in loop)-min(y for x,y in loop))
        factor=max(0.96,1-bevel/max(span,1e-8))
        inset=[(cx+(x-cx)*factor,cy+(y-cy)*factor) for x,y in loop]
        rings.extend([(loop,z1-bevel),(inset,z1)])
    else: rings.append((loop,z1))
    n=len(loop);base=len(vertices)
    for points,z in rings:vertices.extend((x*MM,y*MM,z*MM) for x,y in points)
    faces.append(tuple(base+i for i in reversed(range(n))));material_ids.append(material_id)
    faces.append(tuple(base+(len(rings)-1)*n+i for i in range(n)));material_ids.append(material_id)
    for ring in range(len(rings)-1):
        for i in range(n):
            j=(i+1)%n
            faces.append((base+ring*n+i,base+ring*n+j,base+(ring+1)*n+j,base+(ring+1)*n+i));material_ids.append(material_id)


def _package_mesh(package, height_mm, category, source_tag, pads_only=False):
    key=f'{source_tag}/{package["index"]}/{category}/{height_mm:.6f}/{int(pads_only)}'
    name='PCB EVT3 mesh '+hashlib.sha1(key.encode()).hexdigest()[:18]
    existing=bpy.data.meshes.get(name)
    if existing is not None:return existing
    vertices=[];faces=[];material_ids=[]
    bodies=_outline_loops(package['body_records'])
    if not pads_only and height_mm>0:
        stand_off=min(0.045,height_mm*0.08)
        for loop in bodies:_prism(vertices,faces,material_ids,loop,stand_off,height_mm,0,min(0.03,height_mm*0.1))
    # Pin landings use exact EDA planar shapes. Out-of-plane metal thickness is
    # reconstructed, and does not claim actual lead, solder or silicon structure.
    metal_height=0.035 if pads_only else min(0.14,max(0.035,height_mm*0.14))
    for pin in package['pins']:
        for loop in _outline_loops(pin['records'],circle_segments=16):
            _prism(vertices,faces,material_ids,loop,0,metal_height,1)
    mesh=bpy.data.meshes.new(name)
    mesh.from_pydata(vertices,[],faces);mesh.update()
    mesh.materials.append(_material(category));mesh.materials.append(_material('depop' if pads_only else 'terminal'))
    for poly,idx in zip(mesh.polygons,material_ids):poly.material_index=idx
    mesh['source_package']=package['name']
    mesh['geometry_evidence']='ODB planar body/pin outlines; inferred extrusion/chamfer/metal thickness'
    return mesh


def _height(component, peers):
    original=component.get('height_eda_mm')
    if original is not None and original>0:
        return original,'direct ODB .comp_height',False
    boms=component.get('bom_candidates') or [{}]
    key=(component['package_index'],boms[0].get('manufacturer_part'))
    candidates=peers.get(key,[])
    values=set(round(x[1],6) for x in candidates)
    if len(values)==1:
        return candidates[0][1],f'inherited EDA height from {len(candidates)} same-MPN/same-package peers; original missing',True
    return 0,'height unresolved; no physical body created',False


def build_pcb_population(parent=None, skip_refdes=None, *, board_thickness_mm=None,
                         source_path=None, include_depop_pads=False, collection=None):
    """Return ``{root, objects, metadata}``; no transform, board or cameras created.

    ``skip_refdes`` accepts exact refdes strings or ``pcb.<refdes>`` part IDs.
    Omitted thickness uses the 3.00mm EVT drawing; an override is recorded.
    Optional DEPOP pads have no physical package body and carry that status.
    """
    started=time.perf_counter()
    path=Path(source_path) if source_path else DEFAULT_SOURCE
    raw=path.read_bytes();source_hash=hashlib.sha256(raw).hexdigest()
    data=json.loads(raw)
    thickness=data.get('board_thickness_mm') if board_thickness_mm is None else board_thickness_mm
    if thickness is None or thickness<=0:
        raise ValueError('Positive source board thickness or explicit board_thickness_mm is required')
    skip={str(x).removeprefix('pcb.') for x in (skip_refdes or ())}
    if collection is None:
        collection=bpy.data.collections.new('EVT3 PCB Population')
        bpy.context.scene.collection.children.link(collection)
    root=bpy.data.objects.new('EVT3 PCB population — local ODB coordinates',None)
    collection.objects.link(root);root.parent=parent
    root.empty_display_type='PLAIN_AXES';root.empty_display_size=0.015
    root['part_id']='pcb.population';root['source_revision']=data['source_revision']
    root['coordinate_schema']=data['coordinate_schema'];root['source_sha256']=source_hash
    root['board_thickness_mm']=float(thickness)
    objects=[];parts={};meshes=set();skipped=[];inherited=[]
    peers=collections.defaultdict(list)
    for c in data['components']:
        b=(c.get('bom_candidates') or [{}])[0]
        if c.get('height_eda_mm',0)>0:
            peers[(c['package_index'],b.get('manufacturer_part'))].append((c['refdes'],c['height_eda_mm']))
    for c in data['components']:
        ref=c['refdes'];population=c['population_status']
        if ref in skip:skipped.append(ref);continue
        pads_only=population=='depop-listed'
        if population!='PWA-BOM-listed' and not (include_depop_pads and pads_only):continue
        package=data['packages'][c['package_index']];category=_category(c)
        height,height_source,is_inherited=_height(c,peers)
        if is_inherited:inherited.append(ref)
        mesh=_package_mesh(package,height,category,source_hash[:12],pads_only or height<=0)
        obj=bpy.data.objects.new(f'pcb.{ref} | {package["name"]}',mesh)
        collection.objects.link(obj);obj.parent=root
        a,b,cc,d=c['xy_matrix'];side_sign=1 if c['side']=='top' else -1
        z=0 if side_sign==1 else -float(thickness)*MM
        obj.matrix_local=Matrix(((a,b,0,c['x_mm']*MM),(cc,d,0,c['y_mm']*MM),(0,0,side_sign,z),(0,0,0,1)))
        bom=c.get('bom_candidates') or [{}];first=bom[0]
        part_id='pcb.'+ref
        record=dict(part_id=part_id,refdes=ref,manufacturer=first.get('manufacturer',''),
                    manufacturer_part_number=first.get('manufacturer_part',''),
                    description=first.get('description','Unpopulated source footprint'),
                    function=FUNCTIONS[category],component_class=category,population_status=population,
                    side=c['side'],x_mm=c['x_mm'],y_mm=c['y_mm'],height_mm=height,
                    height_source=height_source,original_height_eda_mm=c.get('height_eda_mm'),
                    evidence_level='source-placement',
                    package_geometry_level='source EDA planar body/pin outlines; inferred 3D extrusion, terminal thickness, chamfer and appearance',
                    source_package_name=package['name'],source_package_index=package['index'],
                    source_revision=data['source_revision'],source_repo=data['source_repository'],
                    source_sha256=source_hash,source_refs=[
                        'HW/EE/GBR/EVT/MB/Zaius-EVT3-LAYOUT-MB-ODB-X02-20161226-Final.zip',
                        'HW/EE/BoM/EVT/ZAIUS-MB-EVT3-HW-EBOM-X00_20161228-add_2nd_source_X15-20170106-Final.xls'],
                    bom_candidates=bom, xy_matrix=c['xy_matrix'],
                    pin_alignment_max_error_mm=c['pin_alignment_max_error_mm'],
                    orientation_basis=c['orientation_basis'],
                    inference_notes='Not a manufacturer package STEP; no reconstructed internal silicon or per-net functional inference.',
                    body_created=not pads_only and height>0)
        for key in ['part_id','refdes','manufacturer','manufacturer_part_number','description','function','component_class',
                    'population_status','side','height_source','evidence_level','package_geometry_level','source_package_name',
                    'source_revision','source_repo','source_sha256','inference_notes']:
            obj[key]=record[key] or ''
        obj['x_mm']=float(c['x_mm']);obj['y_mm']=float(c['y_mm']);obj['height_mm']=float(height)
        obj['source_refs']=json.dumps(record['source_refs'])
        obj['bom_evidence']=json.dumps(bom,separators=(',',':'))
        obj['pin_alignment_max_error_mm']=float(c['pin_alignment_max_error_mm'])
        obj['body_created']=record['body_created']
        objects.append(obj);parts[part_id]=record;meshes.add(mesh.name)
    receipt=dict(created_objects=len(objects),shared_mesh_variants=len(meshes),
                 populated_source_count=sum(c['population_status']=='PWA-BOM-listed' for c in data['components']),
                 skip_refdes=sorted(skip),matched_skipped_refdes=sorted(skipped),
                 inherited_height_refdes=inherited,include_depop_pads=include_depop_pads,
                 board_thickness_mm=float(thickness),thickness_override=board_thickness_mm is not None,
                 coordinates='meters: +X ODBx, +Y ODBy, top Z0, bottom Z-thickness, +Z board normal',
                 source_json=str(path),source_sha256=source_hash,
                 duration_seconds=time.perf_counter()-started,
                 source_pin_alignment_max_error_mm=max(c['pin_alignment_max_error_mm'] for c in data['components']))
    root['receipt']=json.dumps(receipt,separators=(',',':'))
    return {'root':root,'objects':objects,'metadata':{'schema_version':1,'receipt':receipt,'parts':parts}}
