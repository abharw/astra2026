"""Exact analytic bounds cached by definition and rotation; never rotate box corners."""
import sys,json,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import diagnose_cad as d
import numpy as np
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.TDF import TDF_Label
from OCP.collections import Sequence_TDF_Label
from OCP.TCollection import TCollection_AsciiString
from OCP.TDF import TDF_Tool
from OCP.gp import gp_Trsf
from OCP.TopLoc import TopLoc_Location

def labelid(l):
 s=TCollection_AsciiString();TDF_Tool.Entry_s(l,s);return s.ToCString()
def mat(l,st):
 t=st.GetLocation_s(l).Transformation();m=np.eye(4)
 for r in range(3):
  for c in range(4):m[r,c]=t.Value(r+1,c+1)*(.001 if c==3 else 1)
 return m
index=json.loads((d.ROOT/'models/barreleye-evt-mesh/assembly.json').read_text())
d.log('bounds_start',script_sha256=d.sha(Path(__file__)),reason='Prior monolithic source bound stopped after baseline to use corrected OCCT8 getter and cache identical rotated native definitions.')
app,doc,receipt=d.document(index);st=XCAFDoc_DocumentTool.ShapeTool_s(doc.Main());roots=Sequence_TDF_Label();st.GetFreeShapes(roots);occs=[];shapes={};source_nodes=[]
def walk(l,world):
 m=mat(l,st);w=world@m;ref=TDF_Label();definition=l
 if st.IsReference_s(l):
  assert st.GetReferredShape_s(l,ref);definition=ref
 label=labelid(definition);source_nodes.append({'label':labelid(l),'matrix':m})
 if st.IsAssembly_s(definition):
  children=Sequence_TDF_Label();st.GetComponents_s(definition,children,False)
  for i in range(1,children.Length()+1):walk(children.Value(i),w)
 else:
  shapes.setdefault(label,st.GetShape_s(definition));occs.append((label,w))
for i in range(1,roots.Length()+1):walk(roots.Value(i),np.eye(4))
d.log('source_traversal',roots=roots.Length(),source_nodes=len(source_nodes),index_nodes=len(index['nodes']),source_leaves=len(occs),source_definitions=len(shapes));assert len(source_nodes)==len(index['nodes']);matrixerr=[]
for a,b in zip(source_nodes,index['nodes']):
 assert a['label']==b['label'];matrixerr.append(np.abs(a['matrix']-np.array(b['matrix_local_m'])))
source=np.array([[np.inf]*3,[-np.inf]*3]);mesh=source.copy();nativecache={};meshes={};defdict={x['label']:x for x in index['definitions']};localbounds={};localerrors=[];count=0;empty=[]
cachepath=d.OUT/'rotated-native-bounds-cache.json';saved=json.loads(cachepath.read_text()) if cachepath.exists() else {}
for i,(label,w) in enumerate(occs):
 rotation=w[:3,:3];key=(label,tuple(rotation.round(12).ravel()));definition=defdict[label]
 if not definition.get('mesh_path'):
  native_empty=d.bounds(shapes[label]);empty.append({'definition_id':definition['id'],'source_void_bounds':native_empty is None});continue
 diskkey=json.dumps([label,list(key[1])])
 if key not in nativecache and diskkey in saved:nativecache[key]=np.array(saved[diskkey])
 if key not in nativecache:
  tr=gp_Trsf();rr=np.column_stack((rotation,np.zeros(3)));tr.SetValues(*rr.ravel());rotated=shapes[label].Moved(TopLoc_Location(tr));t=time.monotonic();nativecache[key]=d.bounds(rotated);saved[diskkey]=nativecache[key].tolist();cachepath.write_text(json.dumps(saved))
  if time.monotonic()-t>1:d.log('slow_native_bounds',definition=definition['id'],seconds=time.monotonic()-t)
 b=nativecache[key]+w[:3,3]*1000;source[0]=np.minimum(source[0],b[0]);source[1]=np.maximum(source[1],b[1])
 if label not in meshes:
  with np.load(d.ROOT/'models/barreleye-evt-mesh'/definition['mesh_path']) as f:meshes[label]=f['vertices'].astype(np.float64)

 p=meshes[label];q=p@rotation.T+w[:3,3];mesh[0]=np.minimum(mesh[0],q.min(axis=0)*1000);mesh[1]=np.maximum(mesh[1],q.max(axis=0)*1000);count+=len(p)
 if i%100==0:d.log('assembled_bounds_progress',occurrence=i,total=len(occs),source_rotated_shapes=len(nativecache),definitions=len(meshes))
error=np.abs(source-mesh);md=np.max(matrixerr,axis=0)
report={'source_sha256':index['source_sha256'],'method':'Independent recursive XCAF free-root traversal. OCCT AddOptimal(useTriangulation=False,useShapeTolerance=False) on each rotation-transformed native BREP definition, cached by definition+rotation, then translated. Compared with all actual transformed mesh vertices. No rotated AABB corners.','empty_source_definitions':empty,'source_traversal_nodes':len(source_nodes),'mesh_occurrences':len(occs)-len(empty),'source_leaf_occurrences':len(occs),'rotated_native_bounds_computed':len(nativecache),'source_brep_bounds_mm':source.tolist(),'assembled_mesh_vertex_bounds_mm':mesh.tolist(),'source_extents_mm':(source[1]-source[0]).tolist(),'mesh_extents_mm':(mesh[1]-mesh[0]).tolist(),'absolute_bound_endpoint_errors_mm':error.tolist(),'absolute_upper_bound_error_per_axis_mm':error.max(axis=0).tolist(),'local_translation_max_abs_error_mm':(md[:3,3]*1000).tolist(),'local_rotation_max_abs_error':float(md[:3,:3].max()),'vertices_processed_over_occurrences':count,'local_definition_errors':localerrors,'worst_local_definition_bounds':sorted(localerrors,key=lambda x:x['max_endpoint_error_mm'],reverse=True)[:20],'limitations':['Bounds agreement does not prove surface Hausdorff error or detect missing interior faces.','Native bounds derive from source CAD numerical surfaces; no physical measurement asserted.']}
d.dump('bounds-validation.json',report);d.log('bounds_complete',error_mm=report['absolute_upper_bound_error_per_axis_mm'],source_bounds_mm=report['source_brep_bounds_mm'],source_extents_mm=report['source_extents_mm'],mesh_extents_mm=report['mesh_extents_mm'],translation_error_mm=report['local_translation_max_abs_error_mm'])
