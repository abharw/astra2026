"""Create compact Blender inputs from preserved EVT ODB and BOM sources."""
from pathlib import Path
import collections, datetime, hashlib, json, math

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
SOURCE = PROJECT.parent / 'research/ocp-candidates'
ODB = SOURCE / 'inspection/extracted/zaius-EVT/ODB'
LOG = PROJECT / 'logs/pcb-population-actions.jsonl'

def log(detail, **extra):
    with LOG.open('a') as f:
        f.write(json.dumps(dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                               actor='rack_openhardware_research', detail=detail, **extra)) + '\n')

def parse_packages():
    packages = []; current = None; pin = None
    for line in next(ODB.rglob('data')).read_text().splitlines():
        if line.startswith('PKG '):
            fields = line.split()
            current = dict(index=len(packages), name=fields[1], source_record=line,
                           bounds_mm=[float(x)*25.4 for x in fields[3:]], body_records=[], pins=[])
            packages.append(current); pin = None
        elif current and line.startswith('PIN '):
            fields = line.split()
            pin = dict(name=fields[1], source_record=line, x_mm=float(fields[3])*25.4,
                       y_mm=float(fields[4])*25.4, records=[])
            current['pins'].append(pin)
        elif current and line and not line.startswith('#'):
            (pin['records'] if pin else current['body_records']).append(line)
    return packages

def candidate_matrix(angle, reflected):
    t=math.radians(angle); c=math.cos(t); s=math.sin(t)
    # ODB rotation is clockwise; reflection is local X, if requested.
    a=-1 if reflected else 1
    return [c*a, s, -s*a, c]

if __name__ == '__main__':
    log('prepare_source.py start; read original EDA package records and absolute pin locations')
    packages=parse_packages()
    components=json.loads((SOURCE/'inspection/evt-odb-placement-bom.json').read_text())
    by_ref={c['refdes']:c for c in components}
    for path in ODB.rglob('components'):
        current=None
        for line in path.read_text().splitlines():
            if line.startswith('CMP '):
                current=by_ref[line.split(';')[0].split()[6]]; current['source_absolute_pins']=[]
            elif current and line.startswith('TOP '):
                f=line.split()
                current['source_absolute_pins'].append([f[-1],float(f[2])*25.4,float(f[3])*25.4])
    errors=[]; modes=collections.Counter()
    for c in components:
        pkg=packages[c['package_index']]
        pairs=[]
        pin_by_name={p['name']:p for p in pkg['pins']}
        for name,x,y in c.pop('source_absolute_pins',[]):
            if name in pin_by_name:
                p=pin_by_name[name]
                pairs.append((p['x_mm'],p['y_mm'],x-c['x_mm'],y-c['y_mm']))
        candidates=[]
        for angle in [c['rotation_odb_deg'],-c['rotation_odb_deg'],c['rotation_odb_deg']+180,-c['rotation_odb_deg']+180]:
            for mirrored in [False,True]:
                m=candidate_matrix(angle,mirrored)
                error=max((math.hypot(m[0]*x+m[1]*y-u,m[2]*x+m[3]*y-v) for x,y,u,v in pairs),default=0)
                candidates.append((error,angle,mirrored,m))
        # Stable ties choose the direct clockwise ODB rotation before reflection.
        best=min(candidates,key=lambda x:round(x[0],7))
        c['xy_matrix']=best[3];c['pin_alignment_max_error_mm']=best[0]
        c['pin_alignment_pair_count']=len(pairs)
        c['orientation_basis']='local EDA PIN centers matched to absolute ODB TOP records' if pairs else 'ODB clockwise rotation; no pin pair available'
        c['chosen_rotation_clockwise_deg']=best[1];c['chosen_local_x_reflection']=best[2]
        errors.append(best[0]);modes[(c['side'],best[2])]+=1
        c.pop('source',None)
    payload=dict(schema_version=1, source_revision='Zaius EVT3 X02 2016-12-26, BOM X15 2017-01-06',
                 board_thickness_mm=3.0,board_thickness_tolerance_mm=0.3,
                 board_thickness_source='01_pcba-mb_zus-X17-20161223.pdf: note1, all4 pages',
                 coordinate_schema='local ODB x/y, mm; Blender meters; top surface z0, bottom z-3mm; +Z board normal',
                 source_repository='https://github.com/opencomputeproject/zaius-barreleye-g2',
                 source_commit='125c5c264c26f97550da8c19539becb71cf7dc6c',
                 source_license='OCPHL-P-1.0; see retained original license/notice',
                 packages=packages, components=components)
    out=HERE/'population-source.json'
    out.write_text(json.dumps(payload,separators=(',',':')))
    summary=dict(component_records=len(components),package_records=len(packages),
                 max_pin_alignment_error_mm=max(errors),above_0_01mm=sum(e>0.01 for e in errors),
                 orientation_counts={str(k):v for k,v in modes.items()},
                 population_counts=dict(collections.Counter(c['population_status'] for c in components)),
                 output_bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest())
    (HERE/'source-prepare-receipt.json').write_text(json.dumps(summary,indent=2))
    log('prepared source outline, package pin and component placement payload',**summary)
    print(json.dumps(summary,indent=2))
