"""Isolated missing-face retry. Never modifies the original STEP or mesh package."""
import sys,json,copy,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import diagnose_cad as dc
import numpy as np
from OCP.BRep import BRep_Builder
from OCP.BRepTools import BRepTools
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepBuilderAPI import BRepBuilderAPI_Copy
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.ShapeFix import ShapeFix_Face
from OCP.TopoDS import TopoDS_Shape,TopoDS
from OCP.TopAbs import TopAbs_REVERSED

def mesh(f,deflection,angle):
 job=BRepMesh_IncrementalMesh(f,deflection,False,angle,False);job.Perform();tri,loc=dc.tri_of(f)
 if tri is None or tri.NbNodes()==0:return None,int(job.GetStatusFlags())
 pts=[];idx=[]
 for i in range(1,tri.NbNodes()+1):
  p=tri.Node(i).Transformed(loc.Transformation());pts.append([p.X()*.001,p.Y()*.001,p.Z()*.001])
 reverse=f.Orientation()==TopAbs_REVERSED
 for i in range(1,tri.NbTriangles()+1):
  a,b,c=tri.Triangle(i).Get();idx.append([a-1,c-1,b-1] if reverse else [a-1,b-1,c-1])
 return {'vertices':np.array(pts,dtype=np.float32),'triangles':np.array(idx,dtype=np.int32),'palette':np.array([[.57,.59,.61,1]],dtype=np.float32),'material_indices':np.zeros(len(idx),dtype=np.int16)},int(job.GetStatusFlags())

base=json.loads((dc.OUT/'missing-face-baseline.json').read_text());report={'source_sha256':base['source_sha256'],'method':'Individual source face copies only; same-parameter isolated retry, then finer isolated retry, then ShapeFix_Face precision/maxTolerance1e-7mm. Patches accepted only with valid resulting face and endpoint bounds change <=1e-4mm. Degenerate faces have no useful fill.','faces':[]}
(dc.OUT/'patches').mkdir(exist_ok=True)
for d in base['definitions']:
 for old in d['missing_faces']:
  src=dc.OUT/old['source_face_brep'];shape=TopoDS_Shape();BRepTools.Read_s(shape,str(src),BRep_Builder());f=TopoDS.Face(shape);b=dc.bounds(f);ar=old.get('area',{}).get('area_mm2');uv=old.get('uv_bounds',[])
  row={'definition_id':d['definition_id'],'face_index_0based':old['face_index_0based'],'source_face_sha256':dc.sha(src),'source_bounds_mm':b.tolist(),'source_signed_area_mm2':ar,'source_valid':old.get('valid'),'source_uv_bounds':uv,'attempts':[]};report['faces'].append(row)
  if ar is not None and abs(ar)<1e-8:
   row['result']='numerically_zero_area_no_patch';continue
  for method,df,ang in [('isolated_same_parameters',.05,.16),('isolated_finer',.005,.08),('isolated_finest',.0005,.04),('shape_fix_face',.0005,.04)]:
   clone=TopoDS.Face(BRepBuilderAPI_Copy(f,True,False).Shape());fixchanged=False
   if method=='shape_fix_face':
    fix=ShapeFix_Face(clone);fix.SetPrecision(1e-7);fix.SetMaxTolerance(1e-7);fixchanged=fix.Perform();clone=fix.Face()
   data,flags=mesh(clone,df,ang);valid=bool(BRepCheck_Analyzer(clone,True).IsValid());cb=dc.bounds(clone);delta=float(np.abs(cb-b).max());rec={'method':method,'deflection_mm':df,'angle_rad':ang,'mesher_flags':flags,'valid':valid,'bounds_max_change_mm':delta,'triangles':0 if data is None else len(data['triangles']),'shape_fix_changed':bool(fixchanged)};row['attempts'].append(rec)
   if data is not None and valid and delta<=1e-4:
    dest=dc.OUT/'patches'/f"{d['definition_id']}-face-{old['face_index_0based']:05d}.npz";np.savez_compressed(dest,**data);row.update(result='accepted_isolated_face_patch',patch=str(dest.relative_to(dc.OUT)),patch_sha256=dc.sha(dest));break
  else:row['result']='unresolved_no_patch'
 dc.dump('repair-report.json',report);dc.log('definition_repairs',id=d['definition_id'],counts={k:sum(x['result']==k for x in report['faces'] if x['definition_id']==d['definition_id']) for k in ['numerically_zero_area_no_patch','accepted_isolated_face_patch','unresolved_no_patch']})
report['summary']={k:sum(x['result']==k for x in report['faces']) for k in ['numerically_zero_area_no_patch','accepted_isolated_face_patch','unresolved_no_patch']};report['summary']['absolute_integrated_area_mm2']=sum(abs(x['source_signed_area_mm2'] or 0) for x in report['faces']);dc.dump('repair-report.json',report);dc.log('repairs_complete',summary=report['summary'])
