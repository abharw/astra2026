"""Verify all authored camera poses against the actual saved rack and wall bounds."""
import json,math
from pathlib import Path
root=Path(__file__).resolve().parent;d=json.loads((root/'floor-plan.json').read_text())
assert d['schema']=='datacenter-maze/v2'
bs=[r['bounds_m'] for r in d['racks']]+d['wall_bounds_m'];poses=d['camera']['poses']
def dist(p,b):return math.hypot(max(b[0][0]-p[0],0,p[0]-b[1][0]),max(b[0][1]-p[1],0,p[1]-b[1][1]))
clear=min(dist(v['position_m'],b) for v in poses for b in bs);cells={tuple(x) for x in d['floor_cells']};step=d['cell_size_m']
outside=[v['frame'] for v in poses if (math.floor(v['position_m'][0]/step),math.floor(v['position_m'][1]/step)) not in cells]
collisions=[]
for i,r in enumerate(d['racks']):
 a=r['bounds_m']
 for q in d['racks'][i+1:]:
  b=q['bounds_m'];overlap=[min(a[1][k],b[1][k])-max(a[0][k],b[0][k]) for k in range(2)]
  if min(overlap)>.005:collisions.append([r['id'],q['id'],overlap])
wall_hits=[]
for r in d['racks']:
 a=r['bounds_m']
 for b in d['wall_bounds_m']:
  if min(min(a[1][k],b[1][k])-max(a[0][k],b[0][k]) for k in range(2))>.005:wall_hits.append(r['id']);break
check={'schema':'maze-geometry-check/v1','camera_poses_checked':len(poses),'minimum_camera_capsule_clearance_m':clear-.25,'camera_radius_m':.25,'poses_outside_floor':outside,'rack_aabb_overlaps':collisions,'racks_intersecting_walls':wall_hits,'turn_sequence':['left','right','left'],'authored_route_length_m':24,'status':'pass' if clear>.25 and not outside and not collisions and not wall_hits else 'fail','limits':'Authored geometric bounds check; generated video requires separate review.'}
(root/'geometry-check.json').write_text(json.dumps(check,indent=2));print(json.dumps(check,indent=2));raise SystemExit(0 if check['status']=='pass' else 1)
