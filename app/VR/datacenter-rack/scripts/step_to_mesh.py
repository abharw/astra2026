"""Read STEP with OpenCascade XCAF and preserve named assembly occurrences.

No raw STEP coordinate scaling: OCCT resolves mixed source unit contexts into mm.
Mesh coordinates and occurrence translations are converted from mm to SI meters.
Per-topological-face vertices remain separate to retain designed hard boundaries.
The tessellated derivative is for Blender; the original STEP remains authority.
"""
import argparse
import gc
import hashlib
import json
import time
from pathlib import Path

import numpy as np
from OCP.BRep import BRep_Tool
from OCP.BRepBndLib import BRepBndLib
from OCP.BRepMesh import BRepMesh_IncrementalMesh
from OCP.Bnd import Bnd_Box
from OCP.IFSelect import IFSelect_RetDone
from OCP.Quantity import Quantity_Color
from OCP.STEPCAFControl import STEPCAFControl_Reader
from OCP.TCollection import TCollection_ExtendedString, TCollection_AsciiString
from OCP.TDataStd import TDataStd_Name
from OCP.TDF import TDF_Label, TDF_Tool
from OCP.collections import Sequence_TDF_Label as TDF_LabelSequence
from OCP.TDocStd import TDocStd_Document
from OCP.TopAbs import TopAbs_FACE, TopAbs_REVERSED
from OCP.TopExp import TopExp_Explorer
from OCP.TopLoc import TopLoc_Location
from OCP.TopoDS import TopoDS
from OCP.XCAFApp import XCAFApp_Application
from OCP.XCAFDoc import XCAFDoc_DocumentTool, XCAFDoc_ColorSurf, XCAFDoc_ColorGen

def sha(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for chunk in iter(lambda:f.read(8*1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def label_id(label):
    text=TCollection_AsciiString();TDF_Tool.Entry_s(label,text);return text.ToCString()

def label_name(label):
    a=TDataStd_Name()
    if label.FindAttribute(TDataStd_Name.GetID_s(),a):return a.Get().ToExtString()
    return label_id(label)

def matrix(location):
    tr=location.Transformation();m=np.eye(4)
    for r in range(3):
        for c in range(4):m[r,c]=tr.Value(r+1,c+1)*(0.001 if c==3 else 1)
    return m.tolist()

def color(tool,subject):
    rgb=Quantity_Color()
    for mode in [XCAFDoc_ColorSurf,XCAFDoc_ColorGen]:
        try:
            if tool.GetColor(subject,mode,rgb):return [rgb.Red(),rgb.Green(),rgb.Blue(),1]
        except TypeError:
            if tool.GetColor_s(subject,mode,rgb):return [rgb.Red(),rgb.Green(),rgb.Blue(),1]
    return None

def mesh_shape(shape,ct,default_color,deflection,angle):
    job=BRepMesh_IncrementalMesh(shape,deflection,False,angle,True)
    job.Perform()
    points=[];triangles=[];face_colors=[];offset=0;missing=0;faces=0
    ex=TopExp_Explorer(shape,TopAbs_FACE)
    while ex.More():
        face=TopoDS.Face(ex.Current());loc=TopLoc_Location()
        tri=BRep_Tool.Triangulation_s(face,loc);faces+=1
        if tri is None or tri.NbNodes()==0:
            missing+=1;ex.Next();continue
        transform=loc.Transformation();n=tri.NbNodes()
        pts=np.empty((n,3),dtype=np.float32)
        for j in range(1,n+1):
            p=tri.Node(j).Transformed(transform);pts[j-1]=(p.X()*.001,p.Y()*.001,p.Z()*.001)
        idx=np.empty((tri.NbTriangles(),3),dtype=np.int32)
        reverse=face.Orientation()==TopAbs_REVERSED
        for j in range(1,tri.NbTriangles()+1):
            a,b,c=tri.Triangle(j).Get();idx[j-1]=(a-1,c-1,b-1) if reverse else (a-1,b-1,c-1)
        points.append(pts);triangles.append(idx+offset);offset+=n
        rgba=color(ct,face) or default_color or [.57,.59,.61,1]
        face_colors.extend([rgba]*len(idx));ex.Next()
    if not points:return None,{'topological_faces':faces,'missing_faces':missing,'vertices':0,'triangles':0}
    pts=np.concatenate(points);idx=np.concatenate(triangles);cols=np.array(face_colors,dtype=np.float32)
    palette,mi=np.unique(cols,axis=0,return_inverse=True)
    return {'vertices':pts,'triangles':idx,'palette':palette,'material_indices':mi.astype(np.int16)},dict(topological_faces=faces,missing_faces=missing,vertices=len(pts),triangles=len(idx),bounds_m=[pts.min(axis=0).tolist(),pts.max(axis=0).tolist()])

def main():
    p=argparse.ArgumentParser();p.add_argument('step',type=Path);p.add_argument('output',type=Path);p.add_argument('--deflection-mm',type=float,default=.05);p.add_argument('--angle-rad',type=float,default=.16);p.add_argument('--limit',type=int);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);(a.output/'meshes').mkdir(exist_ok=True)
    start=time.monotonic();source_sha=sha(a.step)
    print(json.dumps({'stage':'read-start','path':str(a.step),'sha256':source_sha}),flush=True)
    doc=TDocStd_Document(TCollection_ExtendedString('BinXCAF'))
    app=XCAFApp_Application.GetApplication_s();app.NewDocument(TCollection_ExtendedString('MDTV-XCAF'),doc)
    reader=STEPCAFControl_Reader();reader.SetColorMode(True);reader.SetNameMode(True);reader.SetLayerMode(True)
    status=reader.ReadFile(str(a.step))
    if status!=IFSelect_RetDone:raise RuntimeError(f'STEP read failed {status}')
    print(json.dumps({'stage':'read-complete','seconds':time.monotonic()-start}),flush=True)
    if not reader.Transfer(doc):raise RuntimeError('STEP document transfer failed')
    print(json.dumps({'stage':'transfer-complete','seconds':time.monotonic()-start}),flush=True)
    st=XCAFDoc_DocumentTool.ShapeTool_s(doc.Main());ct=XCAFDoc_DocumentTool.ColorTool_s(doc.Main())
    roots=TDF_LabelSequence();st.GetFreeShapes(roots)
    nodes=[];definitions={};definition_labels={}
    def walk(label,parent=None):
        occurrence_id=f'node-{len(nodes):05d}'
        referred=TDF_Label();definition=label
        if st.IsReference_s(label):
            if not st.GetReferredShape_s(label,referred):raise RuntimeError('Invalid reference '+label_id(label))
            definition=referred
        key=label_id(definition);assembly=st.IsAssembly_s(definition)
        node={'id':occurrence_id,'label':label_id(label),'name':label_name(label),'definition_name':label_name(definition),'definition_id':key,'parent':parent,'assembly':assembly,'matrix_local_m':matrix(st.GetLocation_s(label)),'color_rgba':color(ct,label) or color(ct,definition)}
        nodes.append(node)
        if assembly:
            children=TDF_LabelSequence();st.GetComponents_s(definition,children,False)
            for i in range(1,children.Length()+1):walk(children.Value(i),occurrence_id)
        elif key not in definitions:
            did=f'def-{len(definitions):05d}';definitions[key]={'id':did,'label':key,'name':label_name(definition),'color_rgba':color(ct,definition)};definition_labels[key]=definition
        return occurrence_id
    for i in range(1,roots.Length()+1):walk(roots.Value(i))
    index={'schema':'step-xcaf-blender-mesh/v1','source':str(a.step.resolve()),'source_sha256':source_sha,'units':'meters','occt_import_units':'millimeters','deflection_mm':a.deflection_mm,'angular_deflection_rad':a.angle_rad,'nodes':nodes,'definitions':list(definitions.values()),'status':'structure-loaded','timings':{'read_transfer_structure_seconds':time.monotonic()-start}}
    (a.output/'assembly.json').write_text(json.dumps(index,indent=2))
    print(json.dumps({'stage':'structure','occurrences':len(nodes),'definitions':len(definitions),'seconds':time.monotonic()-start}),flush=True)
    # STEP reader is no longer needed. The document retains transferred shapes.
    del reader;gc.collect()
    for i,(key,info) in enumerate(definitions.items()):
        if a.limit is not None and i>=a.limit:break
        dest=a.output/'meshes'/f"{info['id']}.npz";rpath=dest.with_suffix('.json')
        if dest.exists() and rpath.exists():
            info.update(json.loads(rpath.read_text()));continue
        t=time.monotonic();shape=st.GetShape_s(definition_labels[key])
        result,stats=mesh_shape(shape,ct,info['color_rgba'],a.deflection_mm,a.angle_rad)
        info.update(stats)
        if result is not None:
            np.savez_compressed(dest,**result);info['mesh_path']=str(dest.relative_to(a.output));info['mesh_sha256']=sha(dest)
        info['tessellation_seconds']=time.monotonic()-t
        rpath.write_text(json.dumps(info,indent=2))
        if i%10==0 or i==len(definitions)-1:print(json.dumps({'stage':'mesh','index':i,'name':info['name'],'triangles':stats['triangles'],'seconds':time.monotonic()-start}),flush=True)
        if i%25==0:(a.output/'assembly.json').write_text(json.dumps(index,indent=2))
    index['status']='complete' if all('mesh_path' in d or d.get('vertices')==0 for d in definitions.values()) else 'partial'
    index['timings']['total_seconds']=time.monotonic()-start
    index['totals']={'unique_vertices':sum(d.get('vertices',0) for d in definitions.values()),'unique_triangles':sum(d.get('triangles',0) for d in definitions.values()),'missing_faces':sum(d.get('missing_faces',0) for d in definitions.values())}
    (a.output/'assembly.json').write_text(json.dumps(index,indent=2))
    print(json.dumps({'stage':index['status'],'totals':index['totals'],'seconds':time.monotonic()-start}),flush=True)

if __name__=='__main__':main()
