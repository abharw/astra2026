"""Reuse audited analytic native BREP bounds for the selected current configuration."""
import sys,json
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import diagnose_cad as d
sys.path.insert(0,str(d.ROOT/'source'))
from cad_configuration import build_configuration
index=json.loads((d.ROOT/'models/barreleye-evt-mesh/assembly.json').read_text());full=json.loads((d.OUT/'bounds-validation.json').read_text());assert full['source_sha256']==index['source_sha256'];assert full['local_rotation_max_abs_error']<=1e-15 and max(full['local_translation_max_abs_error_mm'])==0
configuration=build_configuration(None);keep=set(configuration['keep_node_ids']);defs={x['label']:x for x in index['definitions']};repaired={x['definition_id']:x for x in json.loads((d.OUT/'repaired-mesh-receipts.json').read_text())};native=json.loads((d.OUT/'rotated-native-bounds-cache.json').read_text());worlds={};source=np.array([[np.inf]*3,[-np.inf]*3]);mesh=source.copy();meshes={};count=0;vcount=0
for n in index['nodes']:
 local=np.array(n['matrix_local_m']);worlds[n['id']]=worlds[n['parent']]@local if n['parent'] else local
 if n['id'] not in keep or n['assembly']:continue
 definition=defs[n['definition_id']]
 if not definition.get('mesh_path'):continue
 w=worlds[n['id']];key=json.dumps([n['definition_id'],list(w[:3,:3].round(12).ravel())]);b=np.array(native[key])+w[:3,3]*1000;source[0]=np.minimum(source[0],b[0]);source[1]=np.maximum(source[1],b[1]);did=definition['id']
 if did not in meshes:
  if did in repaired:path=d.OUT/repaired[did]['derivative_mesh'];assert d.sha(path)==repaired[did]['derivative_mesh_sha256']
  else:path=d.ROOT/'models/barreleye-evt-mesh'/definition['mesh_path'];assert d.sha(path)==definition['mesh_sha256']
  with np.load(path) as f:meshes[did]=f['vertices'].astype(float)
 p=meshes[did];q=p@w[:3,:3].T+w[:3,3];mesh[0]=np.minimum(mesh[0],q.min(axis=0)*1000);mesh[1]=np.maximum(mesh[1],q.max(axis=0)*1000);count+=1;vcount+=len(p)
error=np.abs(source-mesh);report={'configuration_id':configuration['configuration_id'],'source_sha256':index['source_sha256'],'dependency_full_bounds_sha256':d.sha(d.OUT/'bounds-validation.json'),'method':'Uses rotation-transformed native BREP bounds audited by independent source hierarchy traversal; adds source-verified translations. Mesh extrema use actual occurrence-transformed vertices, including finalized repaired replacements.','source_brep_bounds_mm':source.tolist(),'assembled_mesh_vertex_bounds_mm':mesh.tolist(),'source_extents_mm':(source[1]-source[0]).tolist(),'mesh_extents_mm':(mesh[1]-mesh[0]).tolist(),'absolute_bound_endpoint_errors_mm':error.tolist(),'absolute_upper_bound_error_per_axis_mm':error.max(axis=0).tolist(),'mesh_occurrences':count,'vertices_processed_over_occurrences':vcount,'limitations':['Bounds agreement is not a surface Hausdorff-distance proof.','Only selected source CAD geometry is measured; separately authored PCB reconstruction and study geometry are excluded.']};d.dump('selected-bounds-validation.json',report);d.log('selected_bounds_complete',error_mm=report['absolute_upper_bound_error_per_axis_mm'],source_extents_mm=report['source_extents_mm'],occurrences=count)
