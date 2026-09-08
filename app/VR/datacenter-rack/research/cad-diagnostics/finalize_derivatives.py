"""Rebuild auditable full replacement NPZs from originals plus accepted face patches."""
import sys,json,collections
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import diagnose_cad as d
sys.path.insert(0,str(d.ROOT/'source'))
from cad_configuration import build_configuration
report=json.loads((d.OUT/'repair-report.json').read_text());final=json.loads((d.OUT/'final-selected-face-receipt.json').read_text());index=json.loads((d.ROOT/'models/barreleye-evt-mesh/assembly.json').read_text());defs={x['id']:x for x in index['definitions']}
row=next(x for x in report['faces'] if x['definition_id']=='def-00186' and x['face_index_0based']==10)
row.update(result='accepted_isolated_face_patch',patch=final['patch'],patch_sha256=final['patch_sha256'],patch_triangle_area_mm2=final['triangle_area_mm2'])
if not any(a['method']=='isolated_extremely_fine' for a in row['attempts']):row['attempts'].append({'method':'isolated_extremely_fine','deflection_mm':.00005,'angle_rad':.02,'triangles':final['triangles'],'valid':True,'bounds_max_change_mm':0.0,'shape_fix_changed':False})
report['summary'].update({k:sum(x['result']==k for x in report['faces']) for k in ['numerically_zero_area_no_patch','accepted_isolated_face_patch','unresolved_no_patch']})
groups={}
for f in report['faces']:
 if f['result']=='accepted_isolated_face_patch':groups.setdefault(f['definition_id'],[]).append(f)
receipts=[];(d.OUT/'repaired-meshes').mkdir(exist_ok=True)
for did,ff in groups.items():
 definition=defs[did];src=d.ROOT/'models/barreleye-evt-mesh'/definition['mesh_path'];assert d.sha(src)==definition['mesh_sha256']
 with np.load(src) as orig:old={k:orig[k].copy() for k in orig.files}
 vp=[old['vertices']];tp=[old['triangles']];mi=[old['material_indices']];offset=len(vp[0]);material=len(old['palette'])
 for f in ff:
  patch=d.OUT/f['patch'];assert d.sha(patch)==f['patch_sha256']
  with np.load(patch) as p:
   vp.append(p['vertices']);tp.append(p['triangles']+offset);mi.append(np.full(len(p['triangles']),material,np.int16));offset+=len(p['vertices'])
   q=p['vertices'].astype(float)[p['triangles']]*1000;f['patch_triangle_area_mm2']=float(np.linalg.norm(np.cross(q[:,1]-q[:,0],q[:,2]-q[:,0]),axis=1).sum()/2)
 new={'vertices':np.concatenate(vp),'triangles':np.concatenate(tp),'palette':np.concatenate([old['palette'],np.array([[.57,.59,.61,1]],np.float32)]),'material_indices':np.concatenate(mi)}
 for k in old:assert np.array_equal(new[k][:len(old[k])],old[k]),(did,k)
 dest=d.OUT/'repaired-meshes'/(did+'.npz');np.savez_compressed(dest,**new)
 receipts.append({'definition_id':did,'source_mesh_sha256':definition['mesh_sha256'],'derivative_mesh':str(dest.relative_to(d.OUT)),'derivative_mesh_sha256':d.sha(dest),'original_vertex_prefix_preserved':True,'original_triangle_prefix_preserved':True,'original_material_prefix_preserved':True,'added_faces':len(ff),'added_triangles':sum(len(a) for a in tp[1:]),'remaining_untriangulated_faces':definition['missing_faces']-len(ff),'patch_faces':[f['face_index_0based'] for f in ff],'finish_note':'Neutral patch color: source face color unspecified.'})
c=build_configuration(None);keep=set(c['keep_node_ids']);bylabel={x['label']:x['id'] for x in index['definitions']};counts=collections.Counter(bylabel[n['definition_id']] for n in index['nodes'] if n['id'] in keep and not n['assembly']);rows=[]
for did,num in counts.items():
 ff=[x for x in report['faces'] if x['definition_id']==did]
 if not ff:continue
 rows.append({'definition_id':did,'retained_occurrences':num,'missing_faces_before_per_definition':len(ff),'numerically_zero_area_faces_per_definition':sum(x['result']=='numerically_zero_area_no_patch' for x in ff),'repaired_faces_per_definition':sum(x['result']=='accepted_isolated_face_patch' for x in ff),'unresolved_nonzero_faces_per_definition':sum(x['result']=='unresolved_no_patch' for x in ff),'remaining_absolute_integral_mm2_per_definition':sum(abs(x['source_signed_area_mm2'] or 0) for x in ff if x['result']=='unresolved_no_patch')})
selected={'configuration_id':c['configuration_id'],'configuration_sha256':__import__('hashlib').sha256(json.dumps(c,sort_keys=True).encode()).hexdigest(),'summary':{'selected_affected_definitions':len(rows),'remaining_nonzero_faces_unique':sum(x['unresolved_nonzero_faces_per_definition'] for x in rows),'remaining_nonzero_face_occurrences':sum(x['unresolved_nonzero_faces_per_definition']*x['retained_occurrences'] for x in rows),'remaining_absolute_integrated_area_mm2_unique':sum(x['remaining_absolute_integral_mm2_per_definition'] for x in rows),'remaining_absolute_integrated_area_mm2_occurrence_weighted':sum(x['remaining_absolute_integral_mm2_per_definition']*x['retained_occurrences'] for x in rows)},'rows':rows,'note':'Area is absolute signed CAD integration, not screen-visible hole area. Assumes finalized replacement meshes integrated.'}
d.dump('repair-report.json',report);d.dump('repaired-mesh-receipts.json',receipts);d.dump('selected-configuration-defects.json',selected);d.log('derivatives_finalized',script_sha256=d.sha(Path(__file__)),definitions=len(receipts),faces=sum(x['added_faces'] for x in receipts),triangles=sum(x['added_triangles'] for x in receipts),selected=selected['summary'])
