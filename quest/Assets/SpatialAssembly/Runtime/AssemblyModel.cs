using System;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json;
using UnityEngine;
using UnityEngine.Rendering;

namespace SpatialAssembly {
 [Serializable] public class AssemblyData {
  public string name, description, confidence, captureId,assetId; public int revision;
  public float[] bounds, sizeMeters; public List<PartData> parts; public ResearchData research;
  public void Validate() {
   if(parts==null||parts.Count<1||parts.Count>(assetId==RackResources.AssetId?192:96)||sizeMeters==null||sizeMeters.Length!=3||sizeMeters.Any(x=>!Finite(x)||x<=0||x>20))throw new Exception("Invalid assembly");
   if(bounds==null||bounds.Length!=4||bounds.Any(x=>!Finite(x)||x<0||x>1)||bounds[2]<=bounds[0]||bounds[3]<=bounds[1])throw new Exception("Invalid image bounds");
   var ids=new HashSet<string>();var total=0;
   foreach(var p in parts){if(string.IsNullOrEmpty(p.id)||!ids.Add(p.id)||!new[]{"observed","documented","inferred"}.Contains(p.evidence)||!VectorOK(p.explode,4)||p.primitives==null||p.primitives.Count<1||p.primitives.Count>16)throw new Exception("Invalid part");foreach(var m in p.primitives){total++;m.Validate();}}
   if(total>1024)throw new Exception("Too much geometry");
  }
  public static bool Finite(float x)=>!float.IsNaN(x)&&!float.IsInfinity(x);
  public static bool VectorOK(float[] v,float max)=>v!=null&&v.Length==3&&v.All(x=>Finite(x)&&Mathf.Abs(x)<=max);
  public static Vector3 V(float[] a)=>new Vector3(a[0],a[1],a[2]);
 }
 [Serializable] public class PartData { public string id,name,evidence,description,function,uncertainty;public string parentPartId,assetPackage,assetPart;public int detailLevel;public bool isInternal,isHousing;public string[] sourceIds;public float[] explode;public List<PrimitiveData> primitives; }
 [Serializable] public class SourceData {public string id,url,title,match,kind,findings;}
 [Serializable] public class ResearchData {public string summary,status;public List<SourceData> sources;public string[] gaps;}
 [Serializable] public class PrimitiveData {
  public string kind;public float[] position,size,rotation,color;public List<float[]> vertices;public int[] triangles;
  public void Validate(){
   if(!new[]{"box","sphere","cylinder","cone","torus","mesh"}.Contains(kind)||!AssemblyData.VectorOK(position,2)||!AssemblyData.VectorOK(size,2)||size.Any(x=>x<=0)||!AssemblyData.VectorOK(rotation,360)||!AssemblyData.VectorOK(color,1)||color.Any(x=>x<0))throw new Exception("Invalid primitive");
   if(kind=="mesh"&&(vertices==null||vertices.Count<3||vertices.Count>256||vertices.Any(x=>!AssemblyData.VectorOK(x,.5f))||triangles==null||triangles.Length<3||triangles.Length>1536||triangles.Length%3!=0||triangles.Any(x=>x<0||x>=vertices.Count)))throw new Exception("Invalid mesh");
  }
 }
 public class PartHandle:MonoBehaviour {public PartData Part; public AssemblyVisual Owner;}
 public class AssemblyVisual:MonoBehaviour {
  public AssemblyData Data {get;private set;} public string ObjectId=Guid.NewGuid().ToString();
  public float Explosion;public bool Extracted,Hologram=false,ShowInferred=true; public string Selected;public bool InternalsRevealed;public string FocusedPart;Vector3 focusOffset;
  public Vector3 HomePosition,HomeScale=Vector3.one;public Quaternion HomeRotation=Quaternion.identity;
  public bool IsImportedRack=>Data?.assetId==RackResources.AssetId;
  readonly Dictionary<string,ImportedRackPart> importedParts=new();
  public bool AssetsReady=>importedParts.Values.All(p=>p&&p.Ready);
  public string AssetError=>importedParts.Values.FirstOrDefault(p=>p&&!string.IsNullOrEmpty(p.Error))?.Error;
  public void ReleaseImportedAssets(){foreach(var part in importedParts.Values)if(part)part.Release();}
#if UNITY_EDITOR
  public void SettleInspectionForPreview(){foreach(var p in Data.parts)parts[p.id].localPosition=PartOffset(p.id);}
#endif
  bool moving;float moveTime;Vector3 moveFrom,moveTo,scaleFrom,scaleTo;Quaternion rotationFrom,rotationTo;
  HashSet<string> focusFamily=new();readonly Dictionary<string,PartData> partData=new();readonly Dictionary<string,Vector3> partOffsets=new();readonly Dictionary<string,Transform> parts=new();readonly List<(Renderer renderer,PrimitiveData primitive,PartData part)> surfaces=new();
  public void Build(AssemblyData data){
   data.Validate();Data=data;
   foreach(var p in data.parts){partData[p.id]=p;var group=new GameObject(p.name);group.transform.SetParent(transform,false);parts[p.id]=group.transform;
    if(IsImportedRack&&!string.IsNullOrEmpty(p.assetPackage)){var imported=group.AddComponent<ImportedRackPart>();importedParts[p.id]=imported;imported.Changed+=Restyle;continue;}
    foreach(var primitive in p.primitives){var go=new GameObject(primitive.kind);go.transform.SetParent(group.transform,false);var mesh=Geometry.Create(primitive);
     go.AddComponent<MeshFilter>().sharedMesh=mesh;var r=go.AddComponent<MeshRenderer>();r.material=new Material(Shader.Find("Universal Render Pipeline/Lit")??Shader.Find("Standard"));
     go.transform.localPosition=AssemblyData.V(primitive.position);go.transform.localScale=AssemblyData.V(primitive.size);
     if(primitive.kind=="torus")go.transform.localScale=new Vector3(primitive.size[0],primitive.size[0],primitive.size[2]);
     var e=primitive.rotation;go.transform.localRotation=Quaternion.AngleAxis(e[2],Vector3.forward)*Quaternion.AngleAxis(e[1],Vector3.up)*Quaternion.AngleAxis(e[0],Vector3.right);
     var collider=go.AddComponent<MeshCollider>();collider.sharedMesh=mesh;
     var handle=go.AddComponent<PartHandle>();handle.Part=p;handle.Owner=this;surfaces.Add((r,primitive,p));
    }
   }
   foreach(var p in data.parts)if(importedParts.TryGetValue(p.id,out var imported))imported.Initialize(p,this);
   Restyle();SetExplosion(Explosion);
  }
  public void SetExplosion(float value){Explosion=Mathf.Clamp01(value);if(IsImportedRack&&Explosion>.2f){InternalsRevealed=true;ShowInferred=true;foreach(var p in Data.parts.Where(p=>p.isInternal))partOffsets.Remove(p.id);Restyle();}}
  void Update(){if(moving){moveTime+=Time.deltaTime;float t=Mathf.SmoothStep(0,1,Mathf.Clamp01(moveTime/.32f));transform.position=Vector3.Lerp(moveFrom,moveTo,t);transform.rotation=Quaternion.Slerp(rotationFrom,rotationTo,t);transform.localScale=Vector3.Lerp(scaleFrom,scaleTo,t);if(t>=1)moving=false;}foreach(var p in Data?.parts??new List<PartData>()){var t=parts[p.id];t.localPosition=Vector3.Lerp(t.localPosition,PartOffset(p.id),1-Mathf.Exp(-12*Time.deltaTime));}}
  public HashSet<string> RelatedParts(string id){var ids=new HashSet<string>{id};bool changed=true;while(changed){changed=false;foreach(var part in Data.parts)if(!string.IsNullOrEmpty(part.parentPartId)&&ids.Contains(part.parentPartId)&&ids.Add(part.id))changed=true;}return ids;}
  Vector3 PartOffset(string id){if(partOffsets.TryGetValue(id,out var offset))return offset;var part=partData[id];if(id==FocusedPart)return focusOffset;if(focusFamily.Contains(id))return focusOffset+AssemblyData.V(part.explode)*(IsImportedRack?Mathf.Clamp01((Explosion-.2f)/.8f):.15f);return AssemblyData.V(part.explode)*Explosion;}
  public void RevealInternals(){InternalsRevealed=true;ShowInferred=true;SetExplosion(.25f);Restyle();}
  public void FocusPart(string id,Transform head){var part=Data.parts.First(p=>p.id==id);foreach(var child in RelatedParts(id))partOffsets.Remove(child);FocusedPart=id;focusFamily=RelatedParts(id);Selected=id;InternalsRevealed=true;ShowInferred=true;Vector3 center=Vector3.zero;foreach(var primitive in part.primitives)center+=AssemblyData.V(primitive.position);center/=part.primitives.Count;var direction=transform.InverseTransformDirection(head.position-transform.position).normalized;focusOffset=direction*.55f-center;SetExplosion(.2f);Restyle();}
  public void ReturnPart(string id=null){id=string.IsNullOrEmpty(id)?FocusedPart??Selected:id;if(id!=null){var related=RelatedParts(id);foreach(var child in related)if(parts.TryGetValue(child,out var group)){partOffsets[child]=Vector3.zero;group.localRotation=Quaternion.identity;group.localScale=Vector3.one;}if(related.Contains(FocusedPart??"")){FocusedPart=null;focusFamily.Clear();}}Selected=null;Restyle();}
  public void CloseHousing(){partOffsets.Clear();foreach(var group in parts.Values){group.localRotation=Quaternion.identity;group.localScale=Vector3.one;}FocusedPart=null;focusFamily.Clear();InternalsRevealed=false;Selected=null;SetExplosion(0);Restyle();}
  public bool ManipulatePart(string id,string action,float amount,Transform head){
   if(!parts.TryGetValue(id,out var group))return false;Selected=id;ShowInferred=true;var related=RelatedParts(id);var part=Data.parts.First(p=>p.id==id);Vector3 center=Vector3.zero;foreach(var primitive in part.primitives)center+=AssemblyData.V(primitive.position);center/=part.primitives.Count;var worldCenter=group.TransformPoint(center);
   if(action=="rotate"||action=="scale"){
    var before=group.localToWorldMatrix;var rotationBefore=group.rotation;float scaleFactor=action=="scale"?Mathf.Clamp(amount==0?1.2f:amount,.25f,3):1;
    if(action=="rotate")group.Rotate(Vector3.up,amount==0?30:amount,Space.World);else group.localScale*=scaleFactor;
    group.position+=worldCenter-group.TransformPoint(center);partOffsets[id]=group.localPosition;var delta=group.localToWorldMatrix*before.inverse;var rotationDelta=group.rotation*Quaternion.Inverse(rotationBefore);
    foreach(var child in related){if(child==id||!parts.TryGetValue(child,out var target))continue;target.position=delta.MultiplyPoint3x4(target.position);target.rotation=rotationDelta*target.rotation;target.localScale*=scaleFactor;partOffsets[child]=target.localPosition;}
   }else if(action.StartsWith("move_")){
    var direction=action=="move_left"?-head.right:action=="move_right"?head.right:action=="move_up"?Vector3.up:action=="move_down"?Vector3.down:action=="move_back"?head.forward:-head.forward;var delta=transform.InverseTransformVector(direction*Mathf.Clamp(Mathf.Abs(amount==0?.15f:amount),.02f,1));foreach(var child in related)partOffsets[child]=PartOffset(child)+delta;
   }else return false;Restyle();return true;
  }
  public void CopyInspectionFrom(AssemblyVisual old){
   InternalsRevealed=old.InternalsRevealed;FocusedPart=parts.ContainsKey(old.FocusedPart??"")?old.FocusedPart:null;focusOffset=old.focusOffset;focusFamily=RelatedParts(FocusedPart??"");Selected=parts.ContainsKey(old.Selected??"")?old.Selected:null;
   foreach(var part in Data.parts){var next=parts[part.id];var sourceId=part.id;var seen=new HashSet<string>();while(!old.parts.ContainsKey(sourceId)&&seen.Add(sourceId)){var ancestor=Data.parts.FirstOrDefault(p=>p.id==sourceId);if(string.IsNullOrEmpty(ancestor?.parentPartId))break;sourceId=ancestor.parentPartId;}if(!old.parts.TryGetValue(sourceId,out var previous))continue;next.localPosition=previous.localPosition;next.localRotation=previous.localRotation;next.localScale=previous.localScale;
    if(old.partOffsets.TryGetValue(sourceId,out var offset))partOffsets[part.id]=offset;
   }Restyle();
  }
  public void Select(string id){Selected=id;Restyle();}
  public void Restyle(){
   var openServers=IsImportedRack?new HashSet<string>(Data.parts.Where(p=>!string.IsNullOrEmpty(p.parentPartId)).Select(p=>p.parentPartId)):null;
   foreach(var p in Data.parts){bool visible=ShowInferred||p.evidence!="inferred";
    if(IsImportedRack){if(p.isInternal)visible&=InternalsRevealed;else if(InternalsRevealed&&openServers.Contains(p.id))visible=false;}
    else visible&=!InternalsRevealed||!p.isHousing||p.id==FocusedPart||p.id==Selected;
    parts[p.id].gameObject.SetActive(visible);if(importedParts.TryGetValue(p.id,out var imported))imported.Highlight(Selected==p.id);
   }
   foreach(var x in surfaces){
    var c=Hologram?(x.part.evidence=="inferred"?new Color(1,.55f,.15f):new Color(.08f,.85f,1)):new Color(x.primitive.color[0],x.primitive.color[1],x.primitive.color[2]);
    var material=x.renderer.material;material.color=c;
    if(material.HasProperty("_Metallic"))material.SetFloat("_Metallic",0);
    if(material.HasProperty("_Glossiness"))material.SetFloat("_Glossiness",.28f);
    if(material.HasProperty("_EmissionColor")){material.EnableKeyword("_EMISSION");material.SetColor("_EmissionColor",Selected==x.part.id?new Color(.09f,.07f,.015f):Color.black);}
   }
  }
  public Vector3 InspectionScale(float maxSize){float size=Mathf.Max(transform.lossyScale.x,transform.lossyScale.y,transform.lossyScale.z);return transform.localScale*Mathf.Min(1,maxSize/Mathf.Max(.001f,size));}
  public void StopMotion(){moving=false;}
  public void PullOut(Transform head){Extracted=true;moveTime=0;moveFrom=transform.position;rotationFrom=transform.rotation;scaleFrom=transform.localScale;moveTo=head.position+head.forward*.75f-head.up*.12f;rotationTo=transform.rotation;scaleTo=InspectionScale(.65f);moving=true;}
  public void ReturnHome(){CloseHousing();StopMotion();Extracted=false;transform.localPosition=HomePosition;transform.localRotation=HomeRotation;transform.localScale=HomeScale;SetExplosion(0);}
  void OnDestroy(){ReleaseImportedAssets();foreach(var x in surfaces){if(x.renderer){Geometry.Release(x.renderer.material);var f=x.renderer.GetComponent<MeshFilter>();if(f)Geometry.Release(f.sharedMesh);}}}
 }
 public static class Geometry {
  public static void Release(UnityEngine.Object value){if(Application.isPlaying)UnityEngine.Object.Destroy(value);else UnityEngine.Object.DestroyImmediate(value);}
  public static Mesh Create(PrimitiveData p){
   if(p.kind=="mesh"){var m=new Mesh{name="Source-assisted mesh"};m.SetVertices(p.vertices.Select(AssemblyData.V).ToList());m.SetTriangles(p.triangles,0);m.RecalculateNormals();m.RecalculateBounds();return m;}
   if(p.kind=="cone")return Cone();if(p.kind=="torus")return Torus(Mathf.Clamp(p.size[1]/p.size[0],.02f,.45f));
   var kind=p.kind=="sphere"?PrimitiveType.Sphere:p.kind=="cylinder"?PrimitiveType.Cylinder:PrimitiveType.Cube;
   var temp=GameObject.CreatePrimitive(kind);var mesh=UnityEngine.Object.Instantiate(temp.GetComponent<MeshFilter>().sharedMesh);Release(temp);
   if(p.kind=="cylinder"){var v=mesh.vertices;for(int i=0;i<v.Length;i++)v[i].y*=.5f;mesh.vertices=v;mesh.RecalculateBounds();}return mesh;
  }
  static Mesh Cone(){var vertices=new List<Vector3>();var indices=new List<int>();for(int i=0;i<40;i++){float a=i*Mathf.PI*2/40,b=(i+1)*Mathf.PI*2/40;var p=new Vector3(Mathf.Cos(a)*.5f,-.5f,Mathf.Sin(a)*.5f);var q=new Vector3(Mathf.Cos(b)*.5f,-.5f,Mathf.Sin(b)*.5f);int k=vertices.Count;vertices.AddRange(new[]{p,new Vector3(0,.5f,0),q,p,q,new Vector3(0,-.5f,0)});indices.AddRange(new[]{k,k+1,k+2,k+3,k+4,k+5});}var m=new Mesh();m.SetVertices(vertices);m.SetTriangles(indices,0);m.RecalculateNormals();m.RecalculateBounds();return m;}
  static Mesh Torus(float ratio){var vertices=new List<Vector3>();var indices=new List<int>();float tube=ratio*.5f,ring=.5f-tube;for(int i=0;i<=48;i++){float a=i*Mathf.PI*2/48;for(int j=0;j<=12;j++){float b=j*Mathf.PI*2/12;vertices.Add(new Vector3((ring+tube*Mathf.Cos(b))*Mathf.Cos(a),tube*Mathf.Sin(b),(ring+tube*Mathf.Cos(b))*Mathf.Sin(a)));}}for(int i=0;i<48;i++)for(int j=0;j<12;j++){int k=i*13+j,l=k+13;indices.AddRange(new[]{k,l,k+1,k+1,l,l+1});}var m=new Mesh();m.SetVertices(vertices);m.SetTriangles(indices,0);m.RecalculateNormals();m.RecalculateBounds();return m;}
 }
}
