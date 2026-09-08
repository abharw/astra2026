"""Editable rack cabling. Sources identify parts; installation routes remain inferred.
No scene clearing, rendering, networking or mutation of imported source objects.
"""
import bpy, math, json, hashlib
from pathlib import Path
from mathutils import Vector, Matrix
PROJECT=Path(__file__).resolve().parents[1]
PCB_SOURCE=PROJECT/'research/pcb-population/population-source.json'
CAD_SOURCE=PROJECT/'models/barreleye-evt-mesh/assembly.json'
SOURCE_URL='https://github.com/opencomputeproject/zaius-barreleye-g2'
SCHEMATIC='HW/EE/SCH/EVT/ZAIUS-MB-EVT3-HW-SCH-X01_20161226_0900.pdf'

class Harness:
    def __init__(self,parent=None):
        self.collection=bpy.data.collections.new('Rack external cabling');bpy.context.scene.collection.children.link(self.collection)
        self.objects=[];self.curves=[];self.mat={}
        for key,color,metal,rough in [('blue',(.012,.07,.40,1),0,.32),('black',(.016,.020,.026,1),0,.44),('gray',(.18,.20,.22,1),.8,.28),('gold',(.58,.31,.075,1),.9,.22),('plug',(.55,.62,.69,1),.1,.2),('white',(.86,.89,.93,1),0,.5),('red',(.34,.018,.015,1),0,.38)]:
            m=bpy.data.materials.new('cable.material.'+key);m.diffuse_color=color;m.use_nodes=True;n=m.node_tree.nodes.get('Principled BSDF');n.inputs['Base Color'].default_value=color;n.inputs['Metallic'].default_value=metal;n.inputs['Roughness'].default_value=rough;self.mat[key]=m
        self.root=self.empty('cabling.assembly',parent);self.root.matrix_world=Matrix.Identity(4)
    def tag(self,obj,parent,desc,level='inferred-routing',source=SOURCE_URL):
        self.collection.objects.link(obj);obj.parent=parent;self.objects.append(obj)
        for key,val in dict(part_id=obj.name,description=desc,function=desc,evidence_level=level,source_url=source,manufacturer='Unspecified visual reconstruction',units='metres',physical_validation='not validated').items():obj[key]=val
        return obj
    def empty(self,name,parent=None):
        o=bpy.data.objects.new(name,None);o.empty_display_size=.012;o['assembly']=True
        return self.tag(o,parent,'Editable cable and management hardware assembly')
    def box(self,name,pos,size,mat='black',parent=None,desc='Reconstructed cable accessory'):
        x,y,z=[v/2 for v in size];verts=[(-x,-y,-z),(x,-y,-z),(x,y,-z),(-x,y,-z),(-x,-y,z),(x,-y,z),(x,y,z),(-x,y,z)]
        mesh=bpy.data.meshes.new(name+'.mesh');mesh.from_pydata(verts,[],[(0,3,2,1),(4,5,6,7),(0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7)]);mesh.update();o=bpy.data.objects.new(name,mesh);o.location=pos;mesh.materials.append(self.mat[mat]);self.tag(o,parent or self.root,desc)
        b=o.modifiers.new('Soft manufactured edges','BEVEL');b.width=min(.0006,min(size)/5);b.segments=2
        return o
    def text(self,name,body,pos,size=.006,parent=None):
        data=bpy.data.curves.new(name+'.text','FONT');data.body=body;data.size=size;data.align_x='CENTER';data.extrude=.00001;data.materials.append(self.mat['white']);o=bpy.data.objects.new(name,data);o.location=pos;o.rotation_euler=(math.pi/2,0,0)
        return self.tag(o,parent or self.root,'Editable management port label')
    def curve(self,name,points,radius,mat='blue',parent=None,endpoint_from='',endpoint_to='',desc='Inferred cable installation route'):
        data=bpy.data.curves.new(name+'.route','CURVE');data.dimensions='3D';data.resolution_u=16;data.bevel_depth=radius;data.bevel_resolution=3;data.use_fill_caps=True
        spline=data.splines.new('BEZIER');spline.bezier_points.add(len(points)-1)
        for i,(p,co) in enumerate(zip(spline.bezier_points,points)):
            p.co=co;p.handle_left_type='FREE';p.handle_right_type='FREE'
            before=Vector(points[max(0,i-1)]);after=Vector(points[min(len(points)-1,i+1)])
            direction=(after-before).normalized();length=min((Vector(co)-before).length or 1,(after-Vector(co)).length or 1)*.24
            p.handle_left=Vector(co)-direction*length;p.handle_right=Vector(co)+direction*length
        data.materials.append(self.mat[mat]);obj=bpy.data.objects.new(name,data);self.tag(obj,parent or self.root,desc)
        obj['endpoint_from']=endpoint_from;obj['endpoint_to']=endpoint_to;obj['routing']='inferred installation, not documented cable form or collision-certified route';obj['jacket_outer_diameter_m']=2*radius;obj['control_points_initial_json']=json.dumps(points);obj['assembly']=True
        self.curves.append(obj);return obj
    def plug(self,name,mouth,parent,forward=1):
        # Plug extends toward aisle (-Y); connector proportions are illustrative.
        x,y,z=mouth
        self.box(name+'.body',(x,y-.008,z),(.0115,.018,.0077),'plug',parent,'Simplified modular eight-contact plug; dimensions reconstructed')
        self.box(name+'.boot',(x,y-.023,z),(.010,.014,.0085),'blue',parent,'Flexible cable strain relief boot')
        tab=self.box(name+'.latch',(x,y-.010,z+.005),(.0052,.012,.001),'plug',parent,'Flexible retaining latch; simplified visible geometry');tab.rotation_euler.x=-.13
        for i in range(8):self.box(name+f'.contact{i+1}',(x+(i-3.5)*.00102,y-.0015,z+.0038),(.0005,.007,.0004),'gold',parent,'Eight gold-colored copper-contact representations; no pinout simulation')
        for i in range(3):self.box(name+f'.boot_rib{i}',(x,y-.019-i*.003,z),(.0108,.0008,.0092),'blue',parent,'Strain relief rib')


def load_endpoint_sources():
    """Read the preserved actual EDA placements and CAD occurrence transforms."""
    pcb=json.loads(PCB_SOURCE.read_text());components={c['refdes']:c for c in pcb['components']}
    cad=json.loads(CAD_SOURCE.read_text());world={};nodes={};definitions={d['label']:d for d in cad['definitions']}
    for n in cad['nodes']:
        world[n['id']]=(world[n['parent']] if n['parent'] else Matrix.Identity(4))@Matrix(n['matrix_local_m']);nodes[n['id']]=n
    return components,cad,world,nodes,definitions


def build_cabling(server_slot_origins,parent=None,*,patch_panel_ou=39,internal_ous=None,bmc_height=.026,include_internal_power=True,internal_data_routes=None):
    """Build global rack-coordinate cables, preserving any supplied parent transform.

    Only requested odd server slots 1..35 are cabled. Internal power defaults to
    the first supplied server; explicit data-route records require known endpoints.
    Returns root, collection, objects, curves, endpoints, metadata.
    """
    components,cad,world,nodes,definitions=load_endpoint_sources();h=Harness(parent)
    slots={int(k):tuple(v) for k,v in server_slot_origins.items() if int(k)%2==1 and 1<=int(k)<=35}
    if not slots:raise ValueError('Supply at least one server slot between OU1 and OU35')
    first=min(slots);base_ou=slots[first][2]-(first-1)*.048;fy=slots[first][1];px=slots[first][0];panel_z=base_ou+(patch_panel_ou-1)*.048
    panel=h.empty('cabling.patch_panel.assembly',h.root)
    h.box('cabling.patch_panel.back',(px,fy+.008,panel_z+.024),(.534,.018,.047),'black',panel,'Generic passive 36-port management patch panel; schematic inferred, no switch SKU')
    # Recessed sockets framed by separate parts; no invented active network switch.
    patch_ports={}
    for i in range(36):
        col=i%18;row=i//18;x=px-.225+col*.0265;z=panel_z+.012+row*.023;y=fy-.002
        n=f'cabling.patch.port{i+1:02d}';patch_ports[i+1]=(x,y,z)
        h.box(n+'.recess',(x,y-.001,z),(.0126,.002,.009),'black',panel,'Recessed generic RJ45 management patch position')
        for dx in [-.0068,.0068]:h.box(n+f'.side{dx}',(x+dx,y-.002,z),(.0015,.004,.011),'gray',panel)
        for dz in [-.0052,.0052]:h.box(n+f'.edge{dz}',(x,y-.002,z+dz),(.014,.004,.0013),'gray',panel)
        h.text(n+'.label',str(i+1).zfill(2),(x,y-.004,z+.0061),.0042,panel)
    endpoints={};external=[]
    lan=components['LAN1'];lan_x=px-.228+lan['x_mm']*.001
    for i,(ou,origin) in enumerate(sorted(slots.items())):
        # Each cable has a separate packed lane in a six-by-three vertical bundle.
        lane_x=px-.319-(i%3)*.006;lane_y=fy-.070-(i//3)*.006
        mouth=(lan_x,fy-.006,origin[2]+bmc_height);target=patch_ports[i+1]
        top_turn=panel_z-.047-(i%3)*.008
        points=[(mouth[0],mouth[1]-.028,mouth[2]),(mouth[0],fy-.054,mouth[2]),(mouth[0]-.035,fy-.066,mouth[2]-.010),(lane_x+.029,lane_y,mouth[2]-.012),(lane_x,lane_y,mouth[2]+.016),(lane_x,lane_y,top_turn-.035),(lane_x+.025,lane_y,top_turn),(target[0]-.020,fy-.068,top_turn),(target[0],fy-.054,target[2]-.015),(target[0],target[1]-.028,target[2])]
        curve=h.curve(f'cable.ou{ou:02d}.BMC_LAN1_to_patch{i+1:02d}',points,.00255,endpoint_from=f'server.ou{ou:02d}.pcb.LAN1.PortA',endpoint_to=f'cabling.patch.port{i+1:02d}',desc='Blue management Ethernet patch cable from LAN1 Port A BMC interface to passive patch panel; route and panel inferred')
        curve['cable_category']='Cat6 visual jacket; electrical category compliance not modeled';curve['source_odb_xy_mm']=[lan['x_mm'],lan['y_mm']];curve['mouth_height_basis']='Integrator-supplied conceptual 26mm above chassis base; not a measured jack mating datum';curve['source_schematic']='EVT3 sheet140 LAN1 PortA BCM54612E, BMC PHY'
        h.plug(curve.name+'.server_plug',mouth,curve);h.plug(curve.name+'.panel_plug',target,curve)
        h.text(curve.name+'.tag',f'{ou:02d}',(mouth[0]-.025,fy-.069,mouth[2]+.007),.005,curve)
        endpoints[curve.name]={'from':mouth,'to':target,'source_origin_odb_mm':[lan['x_mm'],lan['y_mm']],'mouth_offset_inferred':True};external.append(curve)
    # Open saddle clips visibly mount the outside bundle to the left frame face.
    for i,z in enumerate([base_ou+.05+j*.25 for j in range(8)]):
        h.box(f'cabling.clip{i}.standoff',(px-.313,fy-.083,z),(.029,.010,.007),'gray',desc='Reconstructed cable saddle standoff to rack left rail')
        h.box(f'cabling.clip{i}.back',(px-.338,fy-.083,z),(.007,.052,.010),'black',desc='Open vertical-bundle saddle')
        for dy in [-.026,.026]:h.box(f'cabling.clip{i}.finger{dy}',(px-.323,fy-.083+dy,z),(.032,.004,.010),'black')
    warnings=[];internal=[]
    selected_internal=sorted(set(internal_ous if internal_ous is not None else [first]))
    if include_internal_power:
        j27=components['J27'];node=nodes['node-09930'];definition=definitions[node['definition_id']]
        # Connector identity and bounding geometry are source CAD; exit face and wire
        # route are visibly reconstructed. No electrical pin mapping is asserted.
        lo,hi=definition['bounds_m'];center=Vector([(lo[k]+hi[k])/2 for k in range(3)]);cad_center=world[node['id']]@center
        transformed=Vector((cad_center.x,-cad_center.z,cad_center.y))
        for ou in selected_internal:
            if ou not in slots:continue
            x,y,z=slots[ou];start=(x+transformed.x,y+transformed.y,z+transformed.z)
            end=(x-.228+j27['x_mm']*.001,y+.00313+j27['y_mm']*.001,z+.0105+(j27.get('height_eda_mm') or 21)*.001)
            route_z=max(end[2]+.012,z+.046)
            points=[start,(start[0]-.025,start[1]-.015,route_z),(x-.215,start[1]-.045,route_z),(end[0]-.014,end[1]+.020,route_z),end]
            obj=h.curve(f'cable.ou{ou:02d}.48V_input_to_J27',points,.0043,'black',endpoint_from=f'server.ou{ou:02d}.cad.node-09930',endpoint_to=f'server.ou{ou:02d}.pcb.J27',desc='Reconstructed 48 V input harness from source TE2204793-2 connector region to motherboard J27; exact plug contacts and routing unverified')
            obj['source_cad_name']=node['definition_name'];obj['source_schematic']='EVT3 sheet250: J27 48 V Input Power CONN, Molex42819-4233';obj['endpoint_geometry']='CAD connector bounding center and ODB package top; wire exit offset not source CAD';internal.append(obj);endpoints[obj.name]={'from':start,'to':end,'source_cad_part':'server.cad.node-09930','source_pcb_part':'pcb.J27'}
        warnings.append('Internal 48V routes have source-bound endpoints but require integrated collision/mating review before acceptance.')
    # Explicit input prevents guessing electrical function from a connector shell.
    for record in internal_data_routes or []:
        required={'name','points','endpoint_from','endpoint_to','source_url','description'}
        if not required.issubset(record):raise ValueError('Internal data route needs explicit named endpoints, points, source URL and description')
        obj=h.curve(record['name'],record['points'],record.get('radius',.002),'black',endpoint_from=record['endpoint_from'],endpoint_to=record['endpoint_to'],desc=record['description']);obj['source_url']=record['source_url'];internal.append(obj)
    if not internal_data_routes:warnings.append('No new internal data cable inferred. CAD already contains HDMI/VGA cable geometry; SAS-style J28/J30/J31/J33 are NVLINK, not storage ports. Counterpart mapping remains open.')
    metadata={'external_cables':len(external),'internal_cables':len(internal),'patch_ports':36,'panel_ou':patch_panel_ou,'patch_panel_status':'Generic passive inferred patch panel; no active network switch SKU','source_odb_sha256':hashlib.sha256(PCB_SOURCE.read_bytes()).hexdigest(),'source_cad_sha256':cad['source_sha256'],'warnings':warnings,'route_status':'editable visual reconstruction; not collision-certified or an electrical wiring plan'}
    h.root['metadata_json']=json.dumps(metadata)
    return {'root':h.root,'collection':h.collection,'objects':h.objects,'curves':h.curves,'external_curves':external,'internal_curves':internal,'endpoints':endpoints,'metadata':metadata}
