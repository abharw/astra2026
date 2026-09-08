using System;
using System.Collections.Generic;
using System.Linq;
using Newtonsoft.Json;
using UnityEngine;
using UnityEngine.Rendering;

namespace SpatialAssembly {
 [Serializable] public class AssemblyData {
  public string name, description, confidence, captureId; public int revision;
  public float[] bounds, sizeMeters; public List<PartData> parts; public ResearchData research;
  public void Validate() {
   if(parts==null||parts.Count<1||parts.Count>24||sizeMeters==null||sizeMeters.Length!=3||sizeMeters.Any(x=>!Finite(x)||x<=0||x>20))throw new Exception("Invalid assembly");
   if(bounds==null||bounds.Length!=4||bounds.Any(x=>!Finite(x)||x<0||x>1)||bounds[2]<=bounds[0]||bounds[3]<=bounds[1])throw new Exception("Invalid image bounds");
   var ids=new HashSet<string>();var total=0;
   foreach(var p in parts){if(string.IsNullOrEmpty(p.id)||!ids.Add(p.id)||!new[]{"observed","documented","inferred"}.Contains(p.evidence)||!VectorOK(p.explode,4)||p.primitives==null||p.primitives.Count<1||p.primitives.Count>16)throw new Exception("Invalid part");foreach(var m in p.primitives){total++;m.Validate();}}
   if(total>256)throw new Exception("Too much geometry");
  }
  public static bool Finite(float x)=>!float.IsNaN(x)&&!float.IsInfinity(x);
  public static bool VectorOK(float[] v,float max)=>v!=null&&v.Length==3&&v.All(x=>Finite(x)&&Mathf.Abs(x)<=max);
  public static Vector3 V(float[] a)=>new Vector3(a[0],a[1],a[2]);
 }
 [Serializable] public class PartData { public string id,name,evidence,description,function,uncertainty;public string[] sourceIds;public float[] explode;public List<PrimitiveData> primitives; }
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
  public float Explosion;public bool Extracted,Hologram=false,ShowInferred=true; public string Selected;
  public Vector3 HomePosition,HomeScale=Vector3.one;public Quaternion HomeRotation=Quaternion.identity;
  bool moving;float moveTime;Vector3 moveFrom,moveTo,scaleFrom,scaleTo;Quaternion rotationFrom,rotationTo;
  readonly Dictionary<string,Transform> parts=new();readonly List<(Renderer renderer,PrimitiveData primitive,PartData part)> surfaces=new();
  public void Build(AssemblyData data){
   data.Validate();Data=data;
   foreach(var p in data.parts){var group=new GameObject(p.name);group.transform.SetParent(transform,false);parts[p.id]=group.transform;
    foreach(var primitive in p.primitives){var go=new GameObject(primitive.kind);go.transform.SetParent(group.transform,false);var mesh=Geometry.Create(primitive);
     go.AddComponent<MeshFilter>().sharedMesh=mesh;var r=go.AddComponent<MeshRenderer>();r.material=new Material(Shader.Find("Universal Render Pipeline/Lit")??Shader.Find("Standard"));
     go.transform.localPosition=AssemblyData.V(primitive.position);go.transform.localScale=AssemblyData.V(primitive.size);
     if(primitive.kind=="torus")go.transform.localScale=new Vector3(primitive.size[0],primitive.size[0],primitive.size[2]);
     var e=primitive.rotation;go.transform.localRotation=Quaternion.AngleAxis(e[2],Vector3.forward)*Quaternion.AngleAxis(e[1],Vector3.up)*Quaternion.AngleAxis(e[0],Vector3.right);
     var collider=go.AddComponent<MeshCollider>();collider.sharedMesh=mesh;
     var handle=go.AddComponent<PartHandle>();handle.Part=p;handle.Owner=this;surfaces.Add((r,primitive,p));
    }
   }
   Restyle();SetExplosion(Explosion);
  }
  public void SetExplosion(float value){Explosion=Mathf.Clamp01(value);}
  void Update(){if(moving){moveTime+=Time.deltaTime;float t=Mathf.SmoothStep(0,1,Mathf.Clamp01(moveTime/.32f));transform.position=Vector3.Lerp(moveFrom,moveTo,t);transform.rotation=Quaternion.Slerp(rotationFrom,rotationTo,t);transform.localScale=Vector3.Lerp(scaleFrom,scaleTo,t);if(t>=1)moving=false;}foreach(var p in Data?.parts??new List<PartData>()){var t=parts[p.id];t.localPosition=Vector3.Lerp(t.localPosition,AssemblyData.V(p.explode)*Explosion,1-Mathf.Exp(-12*Time.deltaTime));}}
  public void Select(string id){Selected=id;Restyle();}
  public void Restyle(){
   foreach(var p in Data.parts)parts[p.id].gameObject.SetActive(ShowInferred||p.evidence!="inferred");
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
  public void ReturnHome(){StopMotion();Extracted=false;transform.localPosition=HomePosition;transform.localRotation=HomeRotation;transform.localScale=HomeScale;SetExplosion(0);}
  void OnDestroy(){foreach(var x in surfaces){if(x.renderer){Geometry.Release(x.renderer.material);var f=x.renderer.GetComponent<MeshFilter>();if(f)Geometry.Release(f.sharedMesh);}}}
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
