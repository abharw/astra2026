import sys,json
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import diagnose_cad as d
from OCP.BRep import BRep_Builder
from OCP.BRepTools import BRepTools
from OCP.TopoDS import TopoDS_Shape,TopoDS
from OCP.BRepBuilderAPI import BRepBuilderAPI_Copy
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.TopAbs import TopAbs_REVERSED
src=d.OUT/'missing-faces/def-00186-face-00010.brep';s=TopoDS_Shape();BRepTools.Read_s(s,str(src),BRep_Builder());original=TopoDS.Face(s);f=TopoDS.Face(BRepBuilderAPI_Copy(original,True,False).Shape());job=BRepMesh_IncrementalMesh(f,.00005,False,.02,False);job.Perform();tri,loc=d.tri_of(f);assert tri is not None
assert BRepCheck_Analyzer(f,True).IsValid();assert np.array_equal(d.bounds(f),d.bounds(original))
p=[];idx=[]
for i in range(1,tri.NbNodes()+1):
 v=tri.Node(i).Transformed(loc.Transformation());p.append([v.X()*.001,v.Y()*.001,v.Z()*.001])
for i in range(1,tri.NbTriangles()+1):
 a,b,c=tri.Triangle(i).Get();idx.append([a-1,c-1,b-1] if f.Orientation()==TopAbs_REVERSED else [a-1,b-1,c-1])
p=np.array(p,np.float32);idx=np.array(idx,np.int32);q=p.astype(float)[idx]*1000;tri_area=float(np.linalg.norm(np.cross(q[:,1]-q[:,0],q[:,2]-q[:,0]),axis=1).sum()/2);native_area=d.area(f)['area_mm2'];assert abs(tri_area-native_area)/native_area<.001
patch=d.OUT/'patches/def-00186-face-00010.npz';np.savez_compressed(patch,vertices=p,triangles=idx,palette=np.array([[.57,.59,.61,1]],np.float32),material_indices=np.zeros(len(idx),np.int16))
receipt={'source_face_sha256':d.sha(src),'method':'isolated unchanged source face copy; linear deflection0.00005mm, angle0.02rad','triangles':len(idx),'valid':True,'source_bounds_exactly_unchanged':True,'source_area_mm2':native_area,'triangle_area_mm2':tri_area,'patch':str(patch.relative_to(d.OUT)),'patch_sha256':d.sha(patch)};d.dump('final-selected-face-receipt.json',receipt);d.log('final_selected_face_repaired',**receipt)
