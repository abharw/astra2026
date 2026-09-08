"""Editable Open Rack V2 mechanical reconstruction, SI metres.
Copyright 2026 project author. Source notices: research/rack-frame/PROVENANCE.md.
The full-depth 48 V integration is a reconstruction, not certified hardware CAD.
No scene clearing, camera creation, rendering, or global settings on import/build.
"""
import bpy
import math
import json
import bmesh
from mathutils import Vector

STANDARD = 'https://www.opencompute.org/documents/openrack-standard-v20-overview'
FRAME = 'https://www.opencompute.org/documents/open-rack-v2-specification-rev12-pdf'
BEL = 'https://www.belfuse.com/resources/datasheets/powersolutions/ds-bps-spstet-07.pdf'
TET = 'https://www.belfuse.com/products/power-supplies/ac-dc-converters/front-end/tet4000-48-069ra'
DEFAULTS = dict(width=.600, depth=1.067, height=2.210, bay_width=.538,
    ou_pitch=.048, ou_count=41, ou_base=.180, equipment_front_y=-.400,
    latch_depth=.7896, support_ous=[1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35],
    power_shelf_ou=37, include_power=True, include_casters=True,
    include_side_panels=False, include_busbar=True, busbar_front_y=None)

class Builder:
    def __init__(self):
        self.collections={}
        for k in ['structure','retention','supports','hardware','power','labels']:
            c=bpy.data.collections.new('rack.'+k);bpy.context.scene.collection.children.link(c);self.collections[k]=c
        self.root=self.empty('rack.assembly',(0,0,0),'structure',None,'integration_inference','Open Rack V2 deep frame with separately sourced 48V power architecture.')
        self.mats={
            'black':self.material('powder_coat_RAL9005',(.014,.017,.021,1),.22,.40),
            'zinc':self.material('zinc_plated_steel',(.47,.50,.52,1),.85,.30),
            'steel':self.material('stainless_fasteners',(.62,.65,.69,1),.95,.24),
            'copper':self.material('copper',(.48,.20,.075,1),.92,.30),
            'silver':self.material('silver_busbar_plating',(.72,.74,.75,1),.97,.23),
            'polymer':self.material('insulator_black',(.014,.018,.023,1),0,.45),
            'rubber':self.material('caster_tread',(.008,.009,.012,1),0,.68),
            'white':self.material('silkscreen',(.80,.83,.86,1),0,.53),
            'green':self.material('status_green',(.055,.36,.10,1),.1,.32),
            'gold':self.material('contact_gold',(.62,.38,.09,1),.95,.22),
        }
    def material(self,n,c,m,r):
        a=bpy.data.materials.new('rack.material.'+n);a.diffuse_color=c;a.use_nodes=True
        s=a.node_tree.nodes.get('Principled BSDF');s.inputs['Base Color'].default_value=c;s.inputs['Metallic'].default_value=m;s.inputs['Roughness'].default_value=r
        return a
    def tag(self,o,group,parent,level,description,url=STANDARD):
        self.collections[group].objects.link(o)
        o.parent=parent if parent is not None else getattr(self,'root',None)
        o['part_id']=o.name;o['source_url']=url;o['evidence_level']=level;o['description']=description or ('Open Rack V2 '+o.name.removeprefix('rack.').replace('.', ' ')+'; authored mechanical reconstruction')
        o['units']='metres';o['manufacturer']='Reference reconstruction';o['physical_validation']='not tested';o['attachment_parent']=o.parent.name if o.parent else ''
        return o
    def empty(self,n,p,group='structure',parent=None,level='reference_reconstruction',desc='',url=STANDARD):
        o=bpy.data.objects.new(n,None);o.location=p;o.empty_display_size=.025;o.empty_display_type='PLAIN_AXES'
        return self.tag(o,group,parent,level,desc,url)
    def mesh(self,n,verts,faces,p=(0,0,0),mat='black',group='structure',parent=None,level='reference_reconstruction',desc='',url=STANDARD,bevel=.00035):
        m=bpy.data.meshes.new(n+'.mesh');m.from_pydata(verts,[],faces);m.update();o=bpy.data.objects.new(n,m);o.location=p
        self.tag(o,group,parent,level,desc,url);o.data.materials.append(self.mats[mat])
        if bevel:
            b=o.modifiers.new('Manufactured edge radius','BEVEL');b.width=bevel;b.segments=2
            b.limit_method='ANGLE'
            w=o.modifiers.new('Weighted normals','WEIGHTED_NORMAL');w.keep_sharp=True
        return o
    def box(self,n,p,d,**kw):
        x,y,z=[v/2 for v in d]
        v=[(-x,-y,-z),(x,-y,-z),(x,y,-z),(-x,y,-z),(-x,-y,z),(x,-y,z),(x,y,z),(-x,y,z)]
        return self.mesh(n,v,[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)],p,**kw)
    def cyl(self,n,p,r,h,axis='Z',segments=24,**kw):
        v=[]
        for z in [-h/2,h/2]:
            for i in range(segments):
                a=2*math.pi*i/segments;co=(r*math.cos(a),r*math.sin(a),z)
                if axis=='X':co=(co[2],co[0],co[1])
                if axis=='Y':co=(co[0],co[2],co[1])
                v.append(co)
        f=[tuple(reversed(range(segments))),tuple(range(segments,2*segments))]
        f += [(i,(i+1)%segments,(i+1)%segments+segments,i+segments) for i in range(segments)]
        return self.mesh(n,v,f,p,**kw)
    def curve(self,n,points,r=.003,mat='polymer',group='hardware',parent=None,level='reference_reconstruction',desc='',url=FRAME):
        c=bpy.data.curves.new(n+'.curve','CURVE');c.dimensions='3D';c.bevel_depth=r;c.bevel_resolution=3;c.resolution_u=16
        s=c.splines.new('POLY');s.points.add(len(points)-1)
        for p,co in zip(s.points,points):p.co=(*co,1)
        o=bpy.data.objects.new(n,c);c.materials.append(self.mats[mat]);return self.tag(o,group,parent,level,desc,url)
    def text(self,n,body,p,size=.008,mat='white',group='labels',parent=None,rotation=(math.pi/2,0,0),url=STANDARD):
        c=bpy.data.curves.new(n+'.text','FONT');c.body=body;c.size=size;c.extrude=.000015;c.align_x='CENTER'
        o=bpy.data.objects.new(n,c);o.location=p;o.rotation_euler=rotation;c.materials.append(self.mats[mat]);return self.tag(o,group,parent,'reference_reconstruction','Editable identification marking',url)
    def holes(self,n,p,w,h,cols,rows,hole_w,hole_h,plane='XZ',circular=False,thickness=.0015,**kw):
        """Mesh sheet with genuine open apertures; tiled annuli, no painted holes."""
        verts=[];faces=[];cw=w/cols;ch=h/rows;steps=16 if circular else 4
        for row in range(rows):
            for col in range(cols):
                cx=(col+.5)*cw-w/2;cy=(row+.5)*ch-h/2
                outer=[];inner=[]
                for k in range(steps):
                    a=2*math.pi*k/steps+math.pi/4
                    dx,dy=math.cos(a),math.sin(a)
                    t=max(abs(dx),abs(dy))
                    outer.append((cx+cw/2*dx/t,cy+ch/2*dy/t))
                    if circular:inner.append((cx+hole_w/2*dx,cy+hole_h/2*dy))
                    else:inner.append((cx+(hole_w/2)*(1 if dx>0 else -1),cy+(hole_h/2)*(1 if dy>0 else -1)))
                start=len(verts)
                for layer in [-thickness/2,thickness/2]:
                    for ring in [outer,inner]:
                        for u,v in ring:verts.append((u,layer,v) if plane=='XZ' else ((layer,u,v) if plane=='YZ' else (u,v,layer)))
                for k in range(steps):
                    j=(k+1)%steps;a=start+k;b=start+j
                    faces += [(a,b,b+steps,a+steps),(a+2*steps,a+3*steps,b+3*steps,b+2*steps),(a+steps,b+steps,b+3*steps,a+3*steps)]
                    # Close only the outside sheet boundary, not shared tile edges.
                    u1,v1=outer[k];u2,v2=outer[j]
                    boundary=(abs(abs(u1)-w/2)<1e-9 and abs(u1-u2)<1e-9) or (abs(abs(v1)-h/2)<1e-9 and abs(v1-v2)<1e-9)
                    if boundary:faces.append((a,a+2*steps,b+2*steps,b))
        o=self.mesh(n,verts,faces,p,bevel=.00010,**kw)
        bm=bmesh.new();bm.from_mesh(o.data)
        bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=1e-8)
        bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
        bm.to_mesh(o.data);bm.free();o.data.update()
        return o
    def bolt(self,n,p,axis='Y',r=.0045,parent=None):
        o=self.cyl(n,p,r,.003,axis=axis,segments=6,mat='steel',group='hardware',parent=parent,desc='Hex head fastener; M6 nominal class, reconstructed head')
        o['nominal_thread']='M6';return o


def build_rack(config=None):
    cfg=dict(DEFAULTS);cfg.update(config or {})
    b=Builder();root=b.root;W,D,H=cfg['width'],cfg['depth'],cfg['height'];z0=cfg['ou_base'];pitch=cfg['ou_pitch'];N=cfg['ou_count'];bay=cfg['bay_width'];fy=cfg['equipment_front_y'];ry=fy+cfg['latch_depth'];top=z0+N*pitch
    meta=dict(config=cfg,coordinate_contract='+X right, +Y front-to-rear, +Z up; floor Z=0; envelope center X=Y=0',
        reconstruction_scope='Published V2 mechanical interfaces with reconstructed frame fabrication. Deep48V busbar and shelf attachment await mating validation.',
        source_dimension_authority={'frame_envelope':FRAME,'ou_bay_latch_interface':STANDARD,'power_shelf':BEL},
        unresolved=['No manufacturer complete rack CAD acquired','No electrical/load/safety test','Deep48V busbar mating not manufacturer verified','Shelf datasheet width inconsistency retained in provenance'],
        server_origin='front bottom center of chassis at selected OU; supports have top surface at same Z',
        sources_license='OCPHL-P standard; OCPHL-R Facebook frame specification; Bel datasheets retain copyright; see provenance')
    root['metadata_json']=json.dumps(meta);root['standard']='Open Rack V2';root['nominal_bus_voltage']=48.0;root['manufacturer']='Authored reference assembly'
    # Bent sheet base and crown. These are open channels, not filled blocks.
    for side,s in [('left',-1),('right',1)]:
        x=s*(W/2-.015)
        for z,label in [(.145,'base'),(H-.025,'crown')]:
            b.box(f'rack.frame.{side}.{label}.web',(x,0,z),(.003,D,.045),url=FRAME,desc='Powder coated folded longitudinal frame web')
            for dz,fl in [(-.021,'lower'),(.021,'upper')]:b.box(f'rack.frame.{side}.{label}.{fl}_flange',(s*(W/2-.025),0,z+dz),(.047,D,.003),url=FRAME)
        for y,label in [(-D/2+.018,'front'),(D/2-.018,'rear')]:
            b.box(f'rack.frame.{side}.{label}.outer_return',(s*(W/2-.0015),y,(.16+H)/2),(.003,.032,H-.16),url=FRAME)
        # V2 side retention webs: 14x18 aperture at 24mm pitch, bore row alongside.
        for y,label in [(fy,'front'),(ry,'rear')]:
            b.holes(f'rack.rail.{side}.{label}.latch_web',(s*(bay/2+.001),y+.007,(z0+top)/2),.026,N*pitch,1,N*2,.014,.018,plane='YZ',mat='black',group='retention',level='published_dimension',desc='14 x 18 mm retention windows, 24 mm pitch; OCP fig3')
            b.holes(f'rack.rail.{side}.{label}.screw_web',(s*(bay/2+.001),y+.033,(z0+top)/2),.026,N*pitch,1,N*2,.0055,.0055,plane='YZ',circular=True,group='retention',level='published_dimension',desc='5.5 mm mounting holes repeated 24 mm; OCP fig3')
            b.holes(f'rack.rail.{side}.{label}.mounting_flange',(s*(bay/2+.012),y-.006,(z0+top)/2),.022,N*pitch,1,N,.0055,.0055,plane='XZ',circular=True,group='retention',desc='Perforated folded flange, nominal M6 screw bore')
            b.box(f'rack.rail.{side}.{label}.rear_return',(s*(bay/2+.022),y+.039,(.166+H-.046)/2),(.002,.090,H-.046-.166),group='retention',desc='Return fold stiffens upright and reaches base/crown flanges; section reconstruction')
        # Structural side center braces are outside 538mm clear equipment bay.
        for z in [.30,1.12,2.05]:
            b.box(f'rack.frame.{side}.brace.{z:.2f}',(s*(W/2-.006),0,z),(.004,.77,.028),url=FRAME,desc='Side frame tie; reconstructed fabrication')
        for ou in range(1,N+1):
            z=z0+(ou-.5)*pitch
            b.text(f'rack.ou.{side}.{ou:02d}',f'{ou:02d}',(s*.286,fy-.008,z-.004),.008)
            # Real projecting rear retaining lance, formed nominal 5.3mm.
            for sub in [0,1]:
                zz=z0+(ou-1)*pitch+sub*pitch/2+.012
                b.box(f'rack.lance.{side}.{ou:02d}.{sub}',(s*(bay/2-.0016),ry+.0033,zz),(.0053,.0066,.0085),group='retention',desc='Formed rear hard-stop lance; fig5 nominal projection5.3mm')
    for y,label in [(-D/2+.02,'front'),(D/2-.02,'rear')]:
        for z,part in [(.145,'base'),(H-.025,'crown')]:
            b.box(f'rack.frame.{label}.{part}.web',(0,y,z),(W,.003,.047),url=FRAME)
            b.box(f'rack.frame.{label}.{part}.flange',(0,y,z+.022),(W,.038,.003),url=FRAME)
            for x in [-.275,.275]:b.bolt(f'rack.fastener.{label}.{part}.{x}',(x,y-.003,z),axis='Y')
    # Four levelling assemblies; load pads contact floor, casters are just raised.
    for side,s in [('left',-1),('right',1)]:
        for end,y in [('front',-.455),('rear',.455)]:
            x=s*.258;n=f'rack.leveler.{side}.{end}'
            b.cyl(n+'.pad',(x,y,.010),.027,.020,mat='rubber',url=FRAME,desc='Swivel base levelling foot; four required by FB specification')
            b.cyl(n+'.swivel',(x,y,.024),.018,.015,mat='steel',url=FRAME)
            b.cyl(n+'.threaded_stem',(x,y,.072),.007,.085,mat='steel',url=FRAME,desc='Adjustable stem; thread diameter reconstructed')
            for i in range(21):b.cyl(n+f'.thread.{i:02d}',(x,y,.039+i*.0028),.0078,.0010,mat='steel',segments=16,bevel=.0001,url=FRAME)
            b.cyl(n+'.locknut',(x,y,.116),.012,.010,segments=6,mat='steel',url=FRAME)
            if cfg['include_casters']:
                xx=x-s*.058;nn=f'rack.caster.{side}.{end}'
                b.cyl(nn+'.tread',(xx,y,.053),.042,.028,axis='X',mat='rubber',url=FRAME)
                b.cyl(nn+'.hub',(xx,y,.053),.017,.029,axis='X',mat='zinc',url=FRAME)
                b.cyl(nn+'.axle',(xx,y,.053),.005,.041,axis='X',mat='steel',url=FRAME)
                for dx in [-.018,.018]:b.box(nn+f'.fork.{dx}',(xx+dx,y,.081),(.004,.037,.065),mat='zinc',url=FRAME)
                b.cyl(nn+'.swivel_bearing',(xx,y,.116),.024,.012,mat='steel',url=FRAME)
                b.box(nn+'.mount_plate',(xx,y,.127),(.061,.068,.005),mat='zinc',url=FRAME)
    # Shelf support pairs: 2mm bearing surface, inside flanges below chassis bottom.
    slots={ou:(0,fy,z0+(ou-1)*pitch) for ou in range(1,N+1)}
    supports=set(cfg['support_ous']);
    if cfg['include_power']:supports.add(cfg['power_shelf_ou'])
    for ou in sorted(supports):
        zz=slots[ou][2]
        for side,s in [('left',-1),('right',1)]:
            n=f'rack.support.ou{ou:02d}.{side}'
            b.box(n+'.bearing',(s*(bay/2-.010),fy+cfg['latch_depth']/2,zz-.001),(.020,cfg['latch_depth'],.002),mat='zinc',group='supports',level='published_dimension',desc='20mm-wide,2mm-thick IT bearing shelf; top equals chassis bottom')
            b.box(n+'.vertical_web',(s*(bay/2+.003),fy+cfg['latch_depth']/2,zz-.010),(.002,cfg['latch_depth'],.020),mat='zinc',group='supports',desc='Removable shelf vertical stiffener')
            for y,lab in [(fy+.030,'front'),(ry-.010,'rear')]:b.bolt(n+'.bolt.'+lab,(s*(bay/2+.004),y,zz-.009),axis='X')
    if cfg['include_side_panels']:
        for side,s in [('left',-1),('right',1)]:b.box(f'rack.panel.{side}',(s*.301,0,1.18),(.0015,D-.08,1.98),group='structure',url=FRAME,desc='Optional removable end-of-row recirculation panel')
    # Central 48V busbar FRU: power strip between split return contacts per figure10.
    busfront=cfg['busbar_front_y'] if cfg['busbar_front_y'] is not None else fy+.6526+(cfg['latch_depth']-.645)
    if cfg['include_busbar']:
        br=b.empty('rack.busbar.assembly',(0,0,0),'power',level='integration_inference',desc='48V busbar cross section from fig10, deep-rack location awaits measured mating confirmation')
        for x,n,offset in [(0,'return',0),(-.006,'power_left',.0015),(.006,'power_right',.0015)]:
            o=b.box('rack.busbar.'+n,(x,busfront+.030+offset,(z0+top)/2),(.0025,.060,N*pitch),mat='silver',group='power',parent=br,desc='Copper busbar with silver interface plating; fig10 topology reconstructed; cross section thickness not a certified dimension')
            o['substrate']='copper';o['finish']='silver plating';o['voltage_net']='return' if n=='return' else '+48V'
        for i,z in enumerate([z0+.035,z0+.50,z0+1.0,z0+1.50,top-.035]):
            b.box(f'rack.busbar.insulator.{i}',(0,busfront+.055,z),(.031,.012,.020),mat='polymer',group='power',parent=br,desc='Electrical isolator; form inferred from busbar assembly requirements')
            b.box(f'rack.busbar.crossbrace.{i}',(0,busfront+.076,z),(.570,.004,.022),mat='black',group='power',parent=br,desc='Busbar rear support cross member')
            for x in [-.276,.276]:b.bolt(f'rack.busbar.mount.{i}.{x}',(x,busfront+.079,z),parent=br)
        b.holes('rack.busbar.rear_shield',(0,busfront+.077,(z0+top)/2),.036,N*pitch,3,N*3,.009,.010,plane='XZ',mat='black',group='power',parent=br,desc='Perforated finger shield, editable open mesh; no safety certification')
        for x,n in [(-.018,'left'),(.018,'right')]:b.box('rack.busbar.shield.'+n,(x,busfront+.037,(z0+top)/2),(.0015,.08,N*pitch),group='power',parent=br,desc='Busbar side guard')
    if cfg['include_power']:_build_bel_power(b,cfg,slots[cfg['power_shelf_ou']],busfront)
    b.text('rack.identification','OPEN RACK V2  |  48V',(0,-D/2-.002,H-.031),.018,url=FRAME)
    # Put assembly manipulation origins at their actual front/bottom mounting datums.
    bpy.context.view_layer.update()
    assemblies=[o for o in b.collections['power'].objects if o.type=='EMPTY' and 'service_origin' in o]
    for o in assemblies:
        matrices={child:child.matrix_world.copy() for child in o.children}
        world=o.matrix_world.copy();world.translation=Vector(o['service_origin']);o.matrix_world=world;bpy.context.view_layer.update()
        for child,matrix in matrices.items():child.matrix_world=matrix
    shelf_z=slots[cfg['power_shelf_ou']][2]
    anchors={
        'busbar_return_front':{'position':(0,busfront,z0),'axis':(0,-1,0),'part':'rack.busbar.return','evidence_level':'integration_inference'},
        'busbar_power_front':{'position':(-.006,busfront+.0015,z0),'axis':(0,-1,0),'part':'rack.busbar.power_left','evidence_level':'integration_inference'},
        'shelf_output_return_end':{'position':(-.010,fy+.8595,shelf_z+.023),'axis':(0,1,0),'part':'rack.power_shelf.output.return','evidence_level':'reference_reconstruction'},
        'shelf_output_positive_end':{'position':(.010,fy+.8595,shelf_z+.023),'axis':(0,1,0),'part':'rack.power_shelf.output.positive','evidence_level':'reference_reconstruction'},
        'shelf_ac_J106':{'position':(-.055,fy+.612,shelf_z+.023),'axis':(0,1,0),'part':'rack.power_shelf.J106.body','evidence_level':'reference_reconstruction'},
        'shelf_ac_J107':{'position':(.116,fy+.612,shelf_z+.023),'axis':(0,1,0),'part':'rack.power_shelf.J107.body','evidence_level':'reference_reconstruction'},
        'shelf_nac_ethernet':{'position':(.236,fy-.0048,shelf_z+.025),'axis':(0,-1,0),'part':'rack.power_shelf.nac.ethernet','evidence_level':'reference_reconstruction'},
    }
    meta['anchors']=anchors;meta['busbar_return_front_y']=busfront
    meta['power_interoperability']='Bel explicitly targets deep48V; geometric shelf-to-busbar mating and server connector positions require verification. Anchors describe authored geometry only.'
    root['metadata_json']=json.dumps(meta)
    root['objects_count']=sum(len(c.objects) for c in b.collections.values())
    return {'root':root,'collections':b.collections,'server_slot_origins':slots,'metadata':meta,'anchors':anchors}


def _build_bel_power(b,cfg,origin,busfront):
    """Bel SPSTET4-07 six-module exterior. No invented rectifier electronics."""
    x,fy,z=origin;w=.5345;d=.600;h=.0465
    r=b.empty('rack.power_shelf.assembly',(0,0,0),'power',level='integration_inference',desc='Bel SPSTET4-07 reference exterior; deep48V intended by manufacturer, rack mating awaits validation',url=BEL)
    r['manufacturer']='Bel Power Solutions';r['model']='SPSTET4-07';r['rated_output_watts']=19260;r['output_voltage_nominal']=54.5;r['datasheet_revision']='BCD.00965 rev.004 (2019-05-27)';r['service_action']='Remove power shelf module toward negative Y';r['service_origin']=(0,fy,z)
    for zz,n in [(z+.00075,'bottom'),(z+h-.00075,'removable_lid')]:b.box('rack.power_shelf.'+n,(0,fy+d/2,zz),(w,d,.0015),mat='zinc',group='power',parent=r,url=BEL,desc='Sheet enclosure 534.5mm width by600mm body depth; manufacturer text has conflicting overall-width value')
    for xx,n in [(-w/2+.001,'left'),(w/2-.001,'right')]:b.box('rack.power_shelf.side.'+n,(xx,fy+d/2,z+h/2),(.002,d,h),mat='zinc',group='power',parent=r,url=BEL)
    # Bay6 at left through bay1 at right; 69mm wide PSU envelopes.
    for i in range(6):
        xx=-.1775+i*.071;pn=f'rack.psu.{6-i:02d}';zz=z+.003;pw=.069;ph=.0406;pd=.5284
        pr=b.empty(pn+'.assembly',(0,0,0),'power',r,'reference_reconstruction','Removable TET4000-48-069RA; casing dimensions documented; exterior feature placement reconstructed',TET)
        pr['manufacturer']='Bel Power Solutions';pr['model']='TET4000-48-069RA';pr['dimensions_mm']='69 x40.6 x528.4';pr['service_direction']='-Y';pr['service_origin']=(xx,fy,zz);pr['internal_electronics']='not modelled: not supported by public mechanical source'
        for zz2,n in [(zz+.0005,'bottom'),(zz+ph-.0005,'lid')]:b.box(pn+'.'+n,(xx,fy+pd/2,zz2),(pw-.001,pd,.001),mat='zinc',group='power',parent=pr,url=TET)
        for xx2,n in [(xx-pw/2+.0005,'left'),(xx+pw/2-.0005,'right')]:b.box(pn+'.'+n,(xx2,fy+pd/2,zz+ph/2),(.001,pd,ph),mat='zinc',group='power',parent=pr,url=TET)
        b.holes(pn+'.front_grille',(xx,fy-.0005,zz+ph/2),pw,ph,11,6,.0037,.0037,plane='XZ',thickness=.001,circular=False,mat='zinc',group='power',parent=pr,url=TET,desc='Open punched front grille reconstructed from manufacturer drawing')
        b.curve(pn+'.pull_handle',[(xx-.029,fy-.004,zz+.009),(xx-.005,fy-.010,zz+.009),(xx+.024,fy-.010,zz+.034),(xx+.027,fy-.004,zz+.034)],r=.0021,mat='zinc',group='power',parent=pr,url=TET,desc='Angled extraction lever follows manufacturer mechanical fig11; fine cross section reconstructed')
        b.box(pn+'.release_latch',(xx+.027,fy-.004,zz+.008),(.006,.005,.013),mat='polymer',group='power',parent=pr,url=TET)
        for j in range(2):b.cyl(pn+f'.led.{j}',(xx+.023+j*.005,fy-.0018,zz+.0114),.0012,.001,axis='Y',mat='green',group='power',parent=pr,url=TET,bevel=.0001)
        b.box(pn+'.rear_connector_housing',(xx,fy+pd-.003,zz+.007),(.05641,.010,.0104),mat='polymer',group='power',parent=pr,url=TET,desc='Amphenol FCI PWRBLADE ULTRA10127397-07H1420LF; interface described in TET datasheet section14')
        for j in range(6):
            co=b.box(pn+f'.connector.P{j+1}',(xx-.024+j*.005,fy+pd+.0025,zz+.007),(.0013,.001,.007),mat='silver',group='power',parent=pr,url=TET,bevel=.0001)
            co['signal']='GND' if j<3 else '+54.5V'
        for j,net in enumerate(['PE','N','L']):
            co=b.box(pn+f'.connector.L{j+1}',(xx+.014+j*.005,fy+pd+.0025,zz+.007),(.0013,.001,.007),mat='silver',group='power',parent=pr,url=TET,bevel=.0001);co['signal']=net
        for row,letter in enumerate('ABC'):
            for col in range(3):b.box(pn+f'.connector.{letter}{col+1}',(xx+.003+col*.002,fy+pd+.0025,zz+.004+row*.0025),(.0006,.001,.0006),mat='gold',group='power',parent=pr,url=TET,bevel=0)
        for yy in [fy+.08,fy+.43]:b.bolt(pn+f'.lid_screw.{yy:.3f}',(xx,yy,zz+ph+.0005),axis='Z',r=.002,parent=pr)
    # Front controller and rear connector panel, positions recovered from sheet fig3/4.
    b.box('rack.power_shelf.nac.casing',(.239,fy+.06,z+h/2),(.047,.120,.041),mat='zinc',group='power',parent=r,url=BEL,desc='Optional NAC slot casing; -07C fitted controller identity')
    b.box('rack.power_shelf.nac.front',(.239,fy-.001,z+h/2),(.045,.002,.041),mat='black',group='power',parent=r,url=BEL)
    b.box('rack.power_shelf.nac.ethernet',(.236,fy-.0025,z+.025),(.013,.004,.012),mat='polymer',group='power',parent=r,url=BEL,desc='10/100 Ethernet management receptacle opening')
    for j in range(8):b.box(f'rack.power_shelf.nac.ethernet.pin.{j}',(.231+j*.0014,fy-.0048,z+.023),(.0006,.0007,.004),mat='gold',group='power',parent=r,url=BEL,bevel=0)
    b.holes('rack.power_shelf.rear_grille',(0,fy+d,z+h/2),w,h,70,6,.004,.004,plane='XZ',mat='zinc',group='power',parent=r,url=BEL,desc='Rear ventilation panel with square perforations')
    for xx,n in [(-.055,'J106'),(.116,'J107')]:
        b.box('rack.power_shelf.'+n+'.body',(xx,fy+d+.004,z+.023),(.050,.014,.019),mat='polymer',group='power',parent=r,url=BEL,desc='Positronic SP5YYE48M0LN9A1/AA-PA1067 three-phase input; exterior only')
        for j in range(5):b.cyl(f'rack.power_shelf.{n}.pin.{j}',(xx-.018+j*.009,fy+d+.012,z+.023),.0017,.003,axis='Y',mat='steel',group='power',parent=r,url=BEL,bevel=.0001)
    # Output extension is documented in deep48V shelf; exact terminal mating location remains editable.
    for xx,n in [(-.010,'return'),(.010,'positive')]:
        b.box('rack.power_shelf.output.'+n,(xx,fy+.72975,z+.023),(.003,.2595,.034),mat='silver',group='power',parent=r,url=BEL,desc='Extended output blade, overall depth859.5mm per datasheet; connection topology must be verified against rack')
    b.text('rack.power_shelf.label','SPSTET4-07  54.5V',(0,fy-.003,z+.041),.004,parent=r,url=BEL)

if __name__=='__main__':
    import argparse,sys,pathlib
    args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
    ap=argparse.ArgumentParser();ap.add_argument('--save');ap.add_argument('--config');ns=ap.parse_args(args)
    cfg=json.loads(pathlib.Path(ns.config).read_text()) if ns.config else None
    result=build_rack(cfg)
    if ns.save:bpy.ops.wm.save_as_mainfile(filepath=str(pathlib.Path(ns.save).resolve()))
    print('RACK_BUILD_COMPLETE',json.dumps({'objects':result['root']['objects_count'],'slots':result['server_slot_origins'],'metadata':result['metadata']}))
