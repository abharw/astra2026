import sys,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'scripts'))
import diagnose_cad as d
from OCP.BRep import BRep_Builder
from OCP.BRepTools import BRepTools
from OCP.TopoDS import TopoDS_Shape,TopoDS
from OCP.BRepAdaptor import BRepAdaptor_Surface
from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeFace,BRepBuilderAPI_Copy
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.BRepCheck import BRepCheck_Analyzer
from OCP.ShapeFix import ShapeFix_Face
from OCP.TopLoc import TopLoc_Location
from OCP.BRep import BRep_Tool
src=d.OUT/'missing-faces/def-00186-face-00010.brep';s=TopoDS_Shape();BRepTools.Read_s(s,str(src),BRep_Builder());f=TopoDS.Face(s);wire=BRepTools.OuterWire_s(f);plane=BRepAdaptor_Surface(f).Plane()
for inside in [True,False]:
 new=BRepBuilderAPI_MakeFace(plane,wire,inside).Face()
 for delta in [.05,.005,.0005,.00005]:
  j=BRepMesh_IncrementalMesh(new,delta,False,.04,False);j.Perform();tri,loc=d.tri_of(new)
  print(inside,delta,j.GetStatusFlags(),0 if tri is None else tri.NbTriangles(),d.area(new),d.bounds(new),BRepCheck_Analyzer(new,True).IsValid(),flush=True)
