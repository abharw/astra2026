"""Read-only source CAD diagnostics, isolated repairs only under research/cad-diagnostics.
OCCT resolves STEP units to mm; stored derivative vertices are SI meters.
No mutation of original STEP, converter or models/barreleye-evt-mesh.
"""
import argparse,gc,hashlib,json,time,datetime,traceback,os
from pathlib import Path
import numpy as np
from OCP.BRep import BRep_Tool
from OCP.BRepTools import BRepTools
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepGProp import BRepGProp
from OCP.BRepCheck import BRepCheck_Analyzer,BRepCheck_Face
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepBuilderAPI import BRepBuilderAPI_Copy
from OCP.BinXCAFDrivers import BinXCAFDrivers
from OCP.Bnd import Bnd_Box
from OCP.GProp import GProp_GProps
from OCP.IFSelect import IFSelect_RetDone
from OCP.TCollection import TCollection_ExtendedString,TCollection_AsciiString
from OCP.TDF import TDF_Label,TDF_Tool
from OCP.collections import Sequence_TDF_Label,Sequence_TCollection_AsciiString
from OCP.TDocStd import TDocStd_Document
from OCP.TopAbs import TopAbs_FACE,TopAbs_EDGE,TopAbs_WIRE,TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.XCAFApp import XCAFApp_Application
from OCP.XCAFDoc import XCAFDoc_DocumentTool
from OCP.ShapeFix import ShapeFix_Shape,ShapeFix_Face
from OCP.ShapeAnalysis import ShapeAnalysis_ShapeTolerance

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'research/cad-diagnostics';OUT.mkdir(parents=True,exist_ok=True)
START=time.monotonic()
def sha(p):
 h=hashlib.sha256()
 with open(p,'rb') as f:
  for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
 return h.hexdigest()
def log(event,**kw):
 o={'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'elapsed_seconds':time.monotonic()-START,'pid':os.getpid(),'owner':'rack_component_knowledge','event':event,**kw}
 with (OUT/'actions.jsonl').open('a') as f:f.write(json.dumps(o,allow_nan=False)+'\n')
 print(json.dumps(o,allow_nan=False),flush=True)
def dump(name,x):
 (OUT/name).write_text(json.dumps(x,indent=2,allow_nan=False)+'\n')
def bounds(shape):
 b=Bnd_Box();BRepBndLib.AddOptimal_s(shape,b,False,False)
 if b.IsVoid():return None
 lo,hi=b.CornerMin(),b.CornerMax()
 return np.array([[lo.X(),lo.Y(),lo.Z()],[hi.X(),hi.Y(),hi.Z()]])
def area(shape):
 p=GProp_GProps();err=BRepGProp.SurfaceProperties_s(shape,p,1e-8,False)
 return {'area_mm2':p.Mass(),'estimated_relative_integration_error':err}
def faces(shape):
 e=TopExp_Explorer(shape,TopAbs_FACE);i=0
 while e.More():
  yield i,TopoDS.Face(e.Current());i+=1;e.Next()
def tri_of(face):
 loc=TopLoc_Location();tri=BRep_Tool.Triangulation_s(face,loc)
 return tri,loc

def get_label(doc,entry):
 l=TDF_Label();TDF_Tool.Label_s(doc.GetData(),entry,l,False)
 if l.IsNull():raise ValueError('Missing source label '+entry)
 return l

def document(index):
 cache=OUT/'barreleye-evt-source.xbf';receipt=cache.with_suffix('.json')
 app=XCAFApp_Application.GetApplication_s();BinXCAFDrivers.DefineFormat_s(app)
 doc=TDocStd_Document(TCollection_ExtendedString('BinXCAF'))
 if cache.exists() and receipt.exists():
  r=json.loads(receipt.read_text())
  if r['step_sha256']!=index['source_sha256']:raise ValueError('Cache source hash mismatch')
  log('cache_open_start',path=str(cache),bytes=cache.stat().st_size)
  status=app.Open(TCollection_ExtendedString(str(cache)),doc)
  if str(status).split('.')[-1]!='PCDM_RS_OK':raise RuntimeError('Cache open failed '+str(status))
  doc=app.GetDocument(app.NbDocuments())
  log('cache_open_complete',status=str(status),documents=app.NbDocuments());return app,doc,r
 src=Path(index['source']);actual=sha(src)
 if actual!=index['source_sha256']:raise ValueError('Input STEP changed')
 log('source_read_start',path=str(src),sha256=actual)
 app.NewDocument(TCollection_ExtendedString('BinXCAF'),doc)
 reader=STEPCAFControl_Reader();reader.SetColorMode(True);reader.SetNameMode(True);reader.SetLayerMode(True)
 status=reader.ReadFile(str(src))
 if status!=IFSelect_RetDone:raise RuntimeError(str(status))
 log('source_read_complete')
 ls,ags,ss=Sequence_TCollection_AsciiString(),Sequence_TCollection_AsciiString(),Sequence_TCollection_AsciiString()
 reader.Reader().FileUnits(ls,ags,ss)
 units={'file_length_units':[ls.Value(i).ToCString() for i in range(1,ls.Length()+1)],'file_angle_units':[ags.Value(i).ToCString() for i in range(1,ags.Length()+1)],'reader_system_length_unit':reader.Reader().SystemLengthUnit()}
 if not reader.Transfer(doc):raise RuntimeError('Transfer failed')
 log('source_transfer_complete',units=units)
 del reader;gc.collect()
 status=app.SaveAs(doc,TCollection_ExtendedString(str(cache)))
 if str(status).split('.')[-1]!='PCDM_SS_OK':raise RuntimeError('Cache save failed '+str(status))
 r={'step':str(src),'step_sha256':actual,'cache':str(cache),'cache_sha256':sha(cache),'units':units,'cache_has_original_source_geometry':True,'cached_before_any_diagnostic_tessellation':True}
 receipt.write_text(json.dumps(r,indent=2)+'\n');log('cache_save_complete',bytes=cache.stat().st_size,sha256=r['cache_sha256']);return app,doc,r

def inspect_face(f):
 rec={}
 for k,fn in [('surface_type',lambda:str(BRepAdaptor_Surface(f).GetType())),('uv_bounds',lambda:list(BRepTools.UVBounds_s(f))),('bounds_mm',lambda:bounds(f).tolist()),('valid',lambda:bool(BRepCheck_Analyzer(f,True).IsValid())),('tolerance_mm',lambda:BRep_Tool.Tolerance_s(f)),('area',lambda:area(f))]:
  try:rec[k]=fn()
  except Exception as e:rec[k+'_error']=str(e)
 try:
  c=BRepCheck_Face(f);rec['wire_checks']={n:str(getattr(c,n)(False)) for n in ['OrientationOfWires','IntersectWires','ClassifyWires']}
 except Exception as e:rec['wire_checks_error']=str(e)
 e=TopExp_Explorer(f,TopAbs_EDGE);cnt=0;deg=0
 while e.More():
  cnt+=1;deg+=int(BRep_Tool.Degenerated_s(TopoDS.Edge(e.Current())));e.Next()
 rec['edge_uses']=cnt;rec['degenerated_edge_uses']=deg
 return rec

def baseline(index,doc):
 st=XCAFDoc_DocumentTool.ShapeTool_s(doc.Main());bad=[d for d in index['definitions'] if d.get('missing_faces',0)]
 result={'source_sha256':index['source_sha256'],'converter_deflection_mm':index['deflection_mm'],'definitions':[]}
 (OUT/'source-brep').mkdir(exist_ok=True);(OUT/'missing-faces').mkdir(exist_ok=True)
 for d in bad:
  t=time.monotonic();shape=st.GetShape_s(get_label(doc,d['label']));base=OUT/'source-brep'/f"{d['id']}.brep"
  if not base.exists():BRepTools.Write_s(shape,str(base))
  j=BRepMesh_IncrementalMesh(shape,index['deflection_mm'],False,index['angular_deflection_rad'],True);j.Perform()
  missing=[]
  for i,f in faces(shape):
   tri,loc=tri_of(f)
   if tri is None or tri.NbNodes()==0:
    rec={'face_index_0based':i,**inspect_face(f)};fp=OUT/'missing-faces'/f"{d['id']}-face-{i:05d}.brep";BRepTools.Write_s(f,str(fp));rec['source_face_brep']=str(fp.relative_to(OUT));rec['source_face_sha256']=sha(fp);missing.append(rec)
  rec={'definition_id':d['id'],'label':d['label'],'name':d['name'],'original_mesh_sha256':d.get('mesh_sha256'),'source_brep_sha256':sha(base),'reported_missing_faces':d['missing_faces'],'reproduced_missing_faces':len(missing),'topological_faces':d['topological_faces'],'mesher_flags':j.GetStatusFlags(),'missing_faces':missing,'seconds':time.monotonic()-t}
  result['definitions'].append(rec);dump('missing-face-baseline.json',result)
  log('definition_baseline',id=d['id'],missing=len(missing),reported=d['missing_faces'],area_mm2=sum(x.get('area',{}).get('area_mm2',0) for x in missing),mesher_flags=j.GetStatusFlags(),seconds=rec['seconds'])
 result['summary']={'definitions':len(bad),'missing_faces':sum(x['reproduced_missing_faces'] for x in result['definitions']),'missing_area_mm2':sum(f.get('area',{}).get('area_mm2',0) for d in result['definitions'] for f in d['missing_faces']),'invalid_faces':sum(not f.get('valid',False) for d in result['definitions'] for f in d['missing_faces'])}
 dump('missing-face-baseline.json',result);log('baseline_complete',summary=result['summary'])

def measure_bounds(index,doc):
 st=XCAFDoc_DocumentTool.ShapeTool_s(doc.Main());roots=Sequence_TDF_Label();st.GetFreeShapes(roots)
 root_bounds=[]
 for i in range(1,roots.Length()+1):
  log('source_root_bounds_start',root=i)
  b=bounds(st.GetShape_s(roots.Value(i)));root_bounds.append(b)
  log('source_root_bounds_complete',root=i,bounds_mm=b.tolist())
 sb=np.array([np.min([b[0] for b in root_bounds],axis=0),np.max([b[1] for b in root_bounds],axis=0)])
 worlds={};groups={};matrix_errors=[];source_local_cache={}
 for n in index['nodes']:
  local=np.array(n['matrix_local_m'],dtype=np.float64);worlds[n['id']]=(worlds[n['parent']]@local) if n['parent'] else local
  if n['label'] not in source_local_cache:
   loc=st.GetLocation_s(get_label(doc,n['label'])).Transformation();m=np.eye(4)
   for rr in range(3):
    for cc in range(4):m[rr,cc]=loc.Value(rr+1,cc+1)*(.001 if cc==3 else 1)
   source_local_cache[n['label']]=m
  delta=np.abs(source_local_cache[n['label']]-local);matrix_errors.append({'node':n['id'],'translation_abs_error_mm':(delta[:3,3]*1000).tolist(),'rotation_max_abs_error':float(delta[:3,:3].max())})
  if not n['assembly']:groups.setdefault(n['definition_id'],[]).append(n)
 mb=np.array([[np.inf]*3,[-np.inf]*3]);def_deltas=[];vertices_processed=0
 for i,d in enumerate(index['definitions']):
  if not d.get('mesh_path'):continue
  with np.load(ROOT/'models/barreleye-evt-mesh'/d['mesh_path']) as f:p=f['vertices'].astype(np.float64)
  native=st.GetShape_s(get_label(doc,d['label']));db=bounds(native);mesh_local=np.array([p.min(axis=0),p.max(axis=0)])*1000
  def_deltas.append({'definition':d['id'],'label':d['label'],'source_brep_bounds_mm':db.tolist(),'mesh_vertex_bounds_mm':mesh_local.tolist(),'absolute_bound_endpoint_errors_mm':np.abs(db-mesh_local).tolist(),'max_error_mm':float(np.abs(db-mesh_local).max())})
  for n in groups.get(d['label'],[]):
   w=worlds[n['id']];q=p@w[:3,:3].T+w[:3,3];mb[0]=np.minimum(mb[0],q.min(axis=0)*1000);mb[1]=np.maximum(mb[1],q.max(axis=0)*1000);vertices_processed+=len(q)
  if i%50==0:log('mesh_bounds_progress',definition=i,vertices_processed=vertices_processed)
 errs=np.abs(sb-mb);report={'source_sha256':index['source_sha256'],'method':'OCCT AddOptimal(useTriangulation=False,useShapeTolerance=False) on complete free source shapes, compared with all actual occurrence-transformed float64 mesh vertices; never transformed AABB corners. Local translations independently checked against source XCAF.','source_brep_bounds_mm':sb.tolist(),'assembled_mesh_vertex_bounds_mm':mb.tolist(),'source_extents_mm':(sb[1]-sb[0]).tolist(),'mesh_extents_mm':(mb[1]-mb[0]).tolist(),'absolute_bound_endpoint_errors_mm':errs.tolist(),'absolute_upper_bound_error_per_axis_mm':errs.max(axis=0).tolist(),'local_translation_max_abs_error_mm':np.max([v['translation_abs_error_mm'] for v in matrix_errors],axis=0).tolist(),'local_rotation_max_abs_error':max(v['rotation_max_abs_error'] for v in matrix_errors),'vertices_processed_over_occurrences':vertices_processed,'local_definition_errors':def_deltas,'worst_local_definition_bounds':sorted(def_deltas,key=lambda x:x['max_error_mm'],reverse=True)[:20],'limitations':['Bounding extremes and transform consistency are not a surface Hausdorff-distance proof.','OCCT bounds inherit source geometry/tolerances; mesh may miss concavities without changing global bounds.']}
 dump('bounds-validation.json',report);log('bounds_complete',source_extents_mm=report['source_extents_mm'],mesh_extents_mm=report['mesh_extents_mm'],error_mm=report['absolute_upper_bound_error_per_axis_mm'],local_translation_error_mm=report['local_translation_max_abs_error_mm'],worst_local_definition=report['worst_local_definition_bounds'][0])

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--stage',choices=['load','baseline','bounds','baseline-bounds'],default='baseline-bounds');a=ap.parse_args()
 indexpath=ROOT/'models/barreleye-evt-mesh/assembly.json';index=json.loads(indexpath.read_text())
 log('diagnostic_start',stage=a.stage,script_sha256=sha(Path(__file__)),assembly_sha256=sha(indexpath),exact_command=' '.join(__import__('sys').argv))
 app,doc,receipt=document(index)
 if a.stage in ['baseline','baseline-bounds']:baseline(index,doc)
 if a.stage in ['bounds','baseline-bounds']:measure_bounds(index,doc)
 log('diagnostic_complete',stage=a.stage)
if __name__=='__main__':
 try:main()
 except Exception as e:
  log('diagnostic_error',error=str(e),traceback=traceback.format_exc());raise
