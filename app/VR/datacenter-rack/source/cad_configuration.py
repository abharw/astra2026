"""Select one inspectable EVT CAD configuration; pure Python, no bpy.

This is an authored, source-position-preserving configuration selection from a
multi-option CAD assembly. It is not a claim that the entire master assembly is
one factory BOM. Unselected variants remain in the original source library.
"""
from pathlib import Path
import collections
import json
import math

PROJECT = Path(__file__).resolve().parents[1]
SOURCE_SHA256 = '823c119e2f7eebae3eda204590c4e6d54e0b990a43e4406987e476bbf41813a1'
PCB_TO_CAD_MATRIX_M = [[1,0,0,-0.228],[0,0,1,0.0105],[0,-1,0,-0.00313],[0,0,0,1]]

def _id(value):
    return f'node-{value:05d}' if isinstance(value,int) else value

def _load(value, default):
    if value is None:value=default
    return json.loads(Path(value).read_text()) if isinstance(value,(str,Path)) else value

def _multiply(a,b):
    return [[sum(a[i][k]*b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

def build_configuration(index, source_report=None):
    """Return a JSON-serializable configuration with all ancestor IDs included.

    index and source_report accept parsed dictionaries or filesystem paths.
    Source report defaults to models/barreleye-source-v001.json. The pinned
    ODB population payload supplies source part/coordinate validation.
    No source nodes or transforms are modified by this function.
    """
    index=_load(index,PROJECT/'models/barreleye-evt-mesh/assembly.json')
    report=_load(source_report,PROJECT/'models/barreleye-source-v001.json')
    if index.get('source_sha256')!=SOURCE_SHA256 or report.get('source_sha256')!=SOURCE_SHA256:
        raise ValueError('Configuration requires the pinned EVT STEP revision; re-review IDs for another source.')
    nodes={n['id']:n for n in index['nodes']}
    children=collections.defaultdict(list)
    for node in nodes.values():children[node['parent']].append(node['id'])
    def subtree(i):
        i=_id(i)
        return [i]+[desc for child in children[i] for desc in subtree(child)]
    def world(i):
        n=nodes[_id(i)];m=n['matrix_local_m']
        return _multiply(world(n['parent']),m) if n['parent'] else m
    part_bounds={p['part_id'].rsplit('.',1)[-1]:p['bounds_m'] for p in report['parts']}
    def bounds(i):
        values=[part_bounds[n] for n in subtree(i) if n in part_bounds]
        if not values:return None
        return [[min(v[0][k] for v in values) for k in range(3)],
                [max(v[1][k] for v in values) for k in range(3)]]
    expected={773:'4_MB-PCBA_ZUS',814:'7_DDR4_SMT_10140702_ZUS',982:'01AF117_ASM_WO_HEATSINK_ASM',
              1161:'01AF117_ASM_WO_HEATSINK_ASM',3418:'HS855600-G2-A_ASM',3505:'HS855600-G2-A_ASM'}
    for i,name in expected.items():
        if nodes[_id(i)]['definition_name']!=name:raise ValueError(f'Unexpected source identity {_id(i)}')
    keep=set();selected=[];reasons={}
    def include(i,reason):
        i=_id(i);keep.update(subtree(i));selected.append({'node_id':i,'name':nodes[i]['definition_name'],'reason':reason})
    def exclude(i,reason):
        for n in subtree(i):keep.discard(n);reasons[n]=reason

    # Root-level hardware is physically placed in the master coordinates.
    # Assembly option families below are excluded explicitly before publication.
    for i in children['node-00000']:
        if i!='node-00771':include(i,'Root assembled hardware, subject to explicit option/pose exclusions below.')
    # Motherboard uses the standalone substrate and one compatible socket family.
    include(773,'EVT motherboard substrate; exact 330.2 x 563.88 x 3 mm source board.')
    for i in range(814,846):include(i,'FCI 10140702 socket family matches populated EVT PWA BOM.')
    for i in [982,1161]:include(i,'One complete POWER9 processor/socket/loading mechanism per source CPU center.')
    for i in [1807,1816,1817,1818,1819]:include(i,'Selected dual-port 25GbE OCP MCX4421A-ACAN and its source mounting latches.')
    for i in [2121,2124,2136,2139]:include(i,'One positioned VTM cooling option at each of four distinct converter-bank locations.')
    # Keep exact or unambiguous part-family CAD matches, and let ODB generate
    # other packages rather than retaining known alternate supplier geometry.
    fixed_matches={879:'J28',880:'J30',881:'J31',882:'J33',893:'J15',896:'J23',897:'J24',898:'J25',899:'J26',
        903:'J9',904:'J10',905:'LAN1',906:'J100',911:'J22',912:'J20',913:'J21',
        927:'PAAU6',929:'PAAU4',930:'PBAU4',932:'PBAU6',937:'PAFU4',938:'PBEU4',
        939:'PBFU4',940:'PAEU4',941:'PAMU4',942:'PBMU4',943:'J2',944:'J6',950:'J14',
        955:'SW3',956:'SW4',960:'J19',961:'J27'}
    for i in fixed_matches:include(i,'Source-positioned CAD part/family matched to the populated ODB reference below.')

    excluded_roots={
        435:'Second HDD drawer is the same drawer translated +455mm into an exploded/open pose; keep node-00276.',
        601:'Backplane rail follows the +455mm exploded drawer; keep node-00594.',
        422:'Alternative tall drive-bay dummy overlaps populated drive carriers; retain small dummy in the unpopulated bay.',
        722:'Blank mezzanine panel is incompatible with selected 25GbE ports.',
        726:'100GbE mezzanine panel is an alternative to selected 25GbE panel node-00723.',
        3592:'GPU K80 tray is an uninstalled option in this no-GPU configuration.',
        9096:'SXM2 GPU module is an uninstalled option in this no-GPU configuration.',
        9774:'Alternative processor heatsink overlaps selected Furukawa node-03505.',
        9835:'Alternative processor heatsink overlaps selected Furukawa node-03418.',
        9897:'Alternative OCP NIC overlaps selected MCX4421A-ACAN.',
        3394:'Generic PCIe size/clearance card; no installed adapter selected for this slot.',
        3395:'Generic PCIe size/clearance card; no installed adapter selected for this slot.',
        3396:'Generic PCIe size/clearance card; no installed adapter selected for this slot.',
        3397:'Generic PCIe size/clearance card; no installed adapter selected for this slot.',
        3404:'Generic PCIe size/clearance card; no installed adapter selected for this slot.',
        9928:'External VGA cable plug is not attached in the assembled default view.',
        9939:'Opaque alternative rear busbar connector overlaps named 2204793-2 option; no source BOM identifies it.',
        2295:'Fan-board EMP whole-board export overlaps standalone board and connectors and contains out-of-board shapes.',
        3317:'Expander EMP whole-board export overlaps standalone board and connectors.',
        2443:'Alternate SAS connector overlaps the first of the 24 selected 787280002 backplane connectors.',
        2286:'Alternate fan-board power-header model overlaps selected HM3508E.',
        2287:'Alternate fan-board header overlaps selected 878325423.',
        2288:'Alternate fan-board header overlaps selected 878325523.',
        2291:'Duplicate fan-board HM3509E source variant; retain POWER9 version node-02292.',
        3299:'Alternate expander header overlaps selected 878325423.',
        3300:'Alternate expander header overlaps selected HM3508E.',
        9741:'GPU-option spacer excluded with GPU assembly.',9744:'GPU-option spacer excluded with GPU assembly.',
        9747:'GPU-option attachment screw excluded with GPU assembly.',9748:'GPU-option attachment screw excluded with GPU assembly.',
        1147:'Unflexed spring alternative overlaps retained flexed/loading pose node-01146.',
        1154:'Unflexed spring alternative overlaps retained flexed/loading pose node-01155.',
        1326:'Unflexed spring alternative overlaps retained flexed/loading pose node-01325.',
        1333:'Unflexed spring alternative overlaps retained flexed/loading pose node-01334.',
    }
    for i,reason in excluded_roots.items():exclude(i,reason)
    # Repeated components contain closed/open poses and old/new fan exports.
    for root in [_id(i) for i in range(2470,2908,19)]:
        for child in children[root]:
            if nodes[child]['definition_name']=='2_FOXCONN-LEVER_AGLAIA':
                m=nodes[child]['matrix_local_m']
                if abs(m[0][2])>0.1:exclude(child,'Open 45-degree carrier lever duplicates the retained closed lever.')
    for root in [2932,2983,3034,3085,3136,3187]:
        for child in children[_id(root)]:
            name=nodes[child]['definition_name']
            if name=='FAN-6056-POWER9':exclude(child,'Second fan-body export duplicates selected named Sunon PF6056 source model.')
            if name=='2_FLAPPER_POWER9':exclude(child,'Old flapper alternative overlaps the three retained FAN-FLAPPER_SH pieces.')
            if name=='456260008_POWER9':exclude(child,'Near-duplicate stationary fan mating connector; retain the root-level fixed connector.')

    # Classify every omitted node, including ancestor scopes never selected.
    for i in nodes:
        if i not in keep and i not in reasons:
            name=nodes[i]['definition_name']
            if 'DDR4_DAISY_CHAIN' in name:reason='Source DIMM validation/clearance candidate; no RAM SKU established. Slot transform retained separately.'
            elif i in subtree(772):reason='Motherboard alternate/obsolete supplier or EMP model; use exact BOM-driven population unless explicitly matched.'
            else:reason='Unselected motherboard accessory, alternative cooling/NIC, or clearance model from the master variant library.'
            reasons[i]=reason
    # Preserve scene hierarchy without reintroducing unselected descendants.
    for i in list(keep):
        parent=nodes[i]['parent']
        while parent:
            keep.add(parent);reasons.pop(parent,None);parent=nodes[parent]['parent']
    pop=_load(None,PROJECT/'research/pcb-population/population-source.json')
    components={c['refdes']:c for c in pop['components'] if c['population_status']=='PWA-BOM-listed'}
    refdes_by_node={_id(i):ref for i,ref in fixed_matches.items()}
    refdes_by_node.update({'node-00982':'U1','node-01161':'U10'})
    dims=[c for ref,c in components.items() if ref.startswith('DIMM')]
    def footprint_center(c):
        x0,y0,x1,y1=pop['packages'][c['package_index']]['bounds_mm'];x=(x0+x1)/2;y=(y0+y1)/2
        a,b,cc,d=c['xy_matrix'];return [c['x_mm']+a*x+b*y,c['y_mm']+cc*x+d*y]
    def cad_center(i):
        bb=bounds(i)
        return [(bb[0][0]+bb[1][0])*500+228,-(bb[0][2]+bb[1][2])*500-3.13]
    for i in range(814,846):
        xy=cad_center(_id(i));candidate=min(dims,key=lambda c:math.dist(xy,footprint_center(c)))
        if math.dist(xy,footprint_center(candidate))>0.2:raise ValueError('DIMM geometry failed ODB footprint-center match')
        refdes_by_node[_id(i)]=candidate['refdes']
    matches=[]
    for i,ref in refdes_by_node.items():
        c=components[ref];bom=c['bom_candidates'][0];source_xy=footprint_center(c)
        actual=cad_center(i);error=math.dist(actual,source_xy)
        if ref in ['U1','U10']:
            m=world(i);actual=[m[0][3]*1000+228,-m[2][3]*1000-3.13]
            source_xy=[c['x_mm'],c['y_mm']];error=math.dist(actual,source_xy)
        matches.append({'node_id':i,'refdes':ref,'manufacturer_part_number':bom.get('manufacturer_part'),
            'cad_name':nodes[i]['definition_name'],'cad_reference_xy_mm':actual,'odb_reference_xy_mm':source_xy,
            'center_error_mm':error,'method':'CPU assembly datum' if ref in ['U1','U10'] else 'CAD planar AABB center versus EDA package/pad envelope center',
            'geometry_evidence':'source CAD selected by part family and location; appearance/suffix equivalence is not proof of a manufacturer-exact body'})
    ram_slots=[]
    for i in range(1913,2007,3):
        nid=_id(i);xy=cad_center(nid)
        c=min(dims,key=lambda c:math.dist(xy,footprint_center(c)))
        ram_slots.append({'source_node_id':nid,'source_name':nodes[nid]['definition_name'],
            'socket_refdes':c['refdes'],'matrix_world_m':world(nid),'bounds_m':bounds(nid),
            'source_socket_xy_mm':[c['x_mm'],c['y_mm']],
            'evidence':'Placement/clearance reference only; DDR4 module SKU, capacity and internal DRAM layout unspecified.'})
    lid=set(subtree(608))
    for i in [629,632,635,638,641]:lid.update(subtree(i))
    lid.intersection_update(keep)
    rendered_bounds=[part_bounds[i] for i in keep if i in part_bounds]
    combined=[[min(v[0][k] for v in rendered_bounds) for k in range(3)],
              [max(v[1][k] for v in rendered_bounds) for k in range(3)]]
    for ref in refdes_by_node.values():
        if ref not in components:raise ValueError(f'Non-populated reference selected: {ref}')
    if len({s['socket_refdes'] for s in ram_slots})!=32:raise ValueError('RAM slot matching is not one-to-one')
    if len({ref for ref in refdes_by_node.values()})!=len(refdes_by_node):raise ValueError('Duplicate CAD-to-PCB reference mapping')
    ancestors_ok=all(nodes[i]['parent'] is None or nodes[i]['parent'] in keep for i in keep)
    gpu_selected=bool(keep.intersection(set(subtree(3592))|set(subtree(9096))))
    duplicates=collections.defaultdict(list)
    for i in keep:
        if not nodes[i]['assembly']:
            key=(nodes[i]['definition_id'],tuple(round(x,7) for row in world(i) for x in row))
            duplicates[key].append(i)
    exact_duplicates=[sorted(ids) for ids in duplicates.values() if len(ids)>1]
    if not ancestors_ok or gpu_selected:raise ValueError('Configuration hierarchy/GPU exclusion failed')
    return {'schema':'barreleye-cad-configuration/v1','configuration_id':'evt3-2ou-no-gpu-25gbe-furukawa',
        'source_sha256':SOURCE_SHA256,'selection_status':'Source-derived assembly selection; not a verified factory configuration BOM.',
        'keep_node_ids':sorted(keep),'keep_part_ids':['server.cad.'+i for i in sorted(keep)],
        'skip_refdes':sorted(refdes_by_node.values()),'refdes_by_node':refdes_by_node,
        'lid_node_ids':sorted(lid),'pcb_to_cad_matrix_m':PCB_TO_CAD_MATRIX_M,
        'ram_slots':ram_slots,'selected_roots':[s for s in selected if s['node_id'] in keep],
        'excluded_nodes':{i:reasons[i] for i in sorted(reasons) if i not in keep},
        'refdes_matches':matches,'cpu_heatsink_root_ids':['node-03418','node-03505'],
        'vrm_heatsink_root_ids':['node-02121','node-02124','node-02136','node-02139'],
        'validation':{'kept_nodes':len(keep),'kept_mesh_occurrences':sum(i in part_bounds for i in keep),
            'excluded_nodes':len(nodes)-len(keep),'source_ram_slots':len(ram_slots),
            'pcb_skip_count':len(refdes_by_node),'matching_max_center_error_mm':max(m['center_error_mm'] for m in matches),
            'matching_above_1mm':[m for m in matches if m['center_error_mm']>1],
            'selected_world_bounds_m':combined,'all_ancestors_included':ancestors_ok,
            'exact_duplicate_leaf_occurrences':exact_duplicates,
            'gpu_geometry_selected':gpu_selected,'source_transforms_modified':False},
        'unverified':['No RAM module SKU in inspected EVT BOM; caller reconstruction must state its evidence level.',
            'Rear 2204793-2 busbar option selected by identifiable CAD name/fit; factory option BOM not found.',
            'Master CAD is multi-option; selection checks do not replace integrated visual and interference review.']}

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--full',action='store_true');args=parser.parse_args()
    result=build_configuration(None)
    print(json.dumps(result if args.full else result['validation'],indent=2))
