using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Networking;
using UnityEngine.Rendering;

namespace SpatialAssembly {
 // Host-owned immutable resources. The voice/model chooses catalog IDs, never file paths.
 public static class RackResources {
  public const string AssetId="arav-rack-v1";
  public static JObject Catalog {get;private set;}
  static Task catalogTask;
  static Cubemap lighting;
  public static void ConfigureLighting(){
   if(!lighting){lighting=new Cubemap(16,TextureFormat.RGBAHalf,true){name="Neutral rack reflection"};
    for(int face=0;face<6;face++){var pixels=new Color[256];for(int y=0;y<16;y++)for(int x=0;x<16;x++){float brightness=face==2?.85f:face==3?.16f:Mathf.Lerp(.22f,.7f,y/15f);pixels[y*16+x]=new Color(brightness*.96f,brightness*.98f,brightness,1);}lighting.SetPixels(pixels,(CubemapFace)face);}lighting.Apply(true,true);
   }RenderSettings.defaultReflectionMode=DefaultReflectionMode.Custom;RenderSettings.customReflectionTexture=lighting;RenderSettings.reflectionIntensity=.7f;
  }
  static readonly Dictionary<string,Package> cache=new();
  static readonly Dictionary<string,Task<Package>> pending=new();
  public static IEnumerable<string> LoadedPackages=>cache.Keys;
  public class Package {public Mesh[] meshes;public Material[][] materials;public JObject definition;public int users;}
  class MeshBytes {public Vector3[] vertices,normals;public int[][] triangles;}
  public static Task EnsureCatalog()=>catalogTask??=ReadCatalog();
  static async Task ReadCatalog(){try{Catalog=JObject.Parse(Encoding.UTF8.GetString(await Read("catalog.json")));if((int?)Catalog["version"]!=1||(string)Catalog["assetId"]!=AssetId)throw new Exception("Unsupported rack catalog");}catch{catalogTask=null;throw;}}
  static async Task<byte[]> Read(string filename){var path=Application.streamingAssetsPath+"/Rack/"+filename;if(!path.Contains("://"))path=new Uri(path).AbsoluteUri;using var req=UnityWebRequest.Get(path);req.timeout=30;var operation=req.SendWebRequest();while(!operation.isDone)await Task.Yield();if(req.result!=UnityWebRequest.Result.Success)throw new Exception("Rack asset unavailable: "+filename+" ("+req.error+")");return req.downloadHandler.data;}
  public static async Task<Package> Acquire(string name){
   await EnsureCatalog();if(!((JObject)Catalog["packages"]).ContainsKey(name))throw new Exception("That detail is not in the source catalog");
   if(!cache.TryGetValue(name,out var result)){
    if(!pending.TryGetValue(name,out var task)){task=Load(name);pending[name]=task;}
    try{result=await task;}finally{if(pending.TryGetValue(name,out var current)&&current==task)pending.Remove(name);}
   }result.users++;return result;
  }
  static async Task<Package> Load(string name){
   var definition=(JObject)Catalog["packages"][name];var bytes=await Read((string)definition["file"]);
   if(bytes.Length!=(int)definition["bytes"])throw new Exception("Rack asset byte count mismatch");
   using(var sha=SHA256.Create()){var hash=BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();if(hash!=(string)definition["sha256"])throw new Exception("Rack asset checksum mismatch");}
   var decoded=await Task.Run(()=>Decode(bytes,(int)definition["decodedBytes"]));
   var resource=new Package{definition=definition,meshes=new Mesh[decoded.Length],materials=new Material[decoded.Length][]};
   try{
    for(int i=0;i<decoded.Length;i++){
     var data=decoded[i];var mesh=new Mesh{name=name+" / "+(string)definition["meshes"][i]["name"],indexFormat=IndexFormat.UInt32};resource.meshes[i]=mesh;
     mesh.vertices=data.vertices;mesh.normals=data.normals;mesh.subMeshCount=data.triangles.Length;
     for(int j=0;j<data.triangles.Length;j++)mesh.SetTriangles(data.triangles[j],j,false);
     mesh.RecalculateBounds();mesh.UploadMeshData(true);
     resource.materials[i]=((JArray)definition["meshes"][i]["materials"]).Select(value=>{
      var shader=Shader.Find("Universal Render Pipeline/Lit")??Shader.Find("Standard");if(!shader)throw new Exception("Rack material shader unavailable");
      var material=new Material(shader){name=(string)value["name"],enableInstancing=true};material.EnableKeyword("_EMISSION");var c=value["color"].ToObject<float[]>();material.color=new Color(c[0],c[1],c[2],c[3]);
      material.SetFloat("_Metallic",(float)value["metallic"]);float smooth=1-(float)value["roughness"];
      if(material.HasProperty("_Smoothness"))material.SetFloat("_Smoothness",smooth);if(material.HasProperty("_Glossiness"))material.SetFloat("_Glossiness",smooth);return material;
     }).ToArray();
     await Task.Yield();
    }cache[name]=resource;return resource;
   }catch{Destroy(resource);throw;}
  }
  static MeshBytes[] Decode(byte[] bytes,int expected){
   if(expected<=0||expected>160*1024*1024)throw new Exception("Rack asset exceeds decoding budget");
   using var compressed=new MemoryStream(bytes);using var gzip=new GZipStream(compressed,CompressionMode.Decompress);using var decoded=new MemoryStream(expected);
   byte[] chunk=new byte[65536];int read;while((read=gzip.Read(chunk,0,chunk.Length))>0){if(decoded.Length+read>expected)throw new Exception("Rack asset exceeds declared size");decoded.Write(chunk,0,read);}if(decoded.Length!=expected)throw new Exception("Incomplete rack asset");decoded.Position=0;
   using var reader=new BinaryReader(decoded);if(Encoding.ASCII.GetString(reader.ReadBytes(8))!="RACKM001")throw new Exception("Invalid rack mesh header");
   int count=reader.ReadInt32();if(count<1||count>64)throw new Exception("Invalid rack mesh count");var meshes=new MeshBytes[count];
   for(int i=0;i<count;i++){
    int n=reader.ReadInt32();if(n<3||n>1500000)throw new Exception("Invalid rack vertex count");var data=new MeshBytes{vertices=new Vector3[n],normals=new Vector3[n]};meshes[i]=data;
    for(int a=0;a<2;a++)for(int v=0;v<n;v++){var value=new Vector3(reader.ReadSingle(),reader.ReadSingle(),reader.ReadSingle());if(!AssemblyData.Finite(value.x)||!AssemblyData.Finite(value.y)||!AssemblyData.Finite(value.z))throw new Exception("Invalid rack vertex");if(a==0)data.vertices[v]=value;else data.normals[v]=value;}
    int groups=reader.ReadInt32();if(groups<1||groups>64)throw new Exception("Invalid rack material count");data.triangles=new int[groups][];
    for(int g=0;g<groups;g++){int length=reader.ReadInt32();if(length<0||length>6000000||length%3!=0)throw new Exception("Invalid rack indices");var indices=new int[length];data.triangles[g]=indices;for(int t=0;t<length;t++){indices[t]=reader.ReadInt32();if(indices[t]<0||indices[t]>=n)throw new Exception("Rack index out of range");}}
   }if(decoded.Position!=decoded.Length)throw new Exception("Unexpected rack mesh bytes");return meshes;
  }
  public static void Release(string name){if(cache.TryGetValue(name,out var resource)&&--resource.users<=0){cache.Remove(name);Destroy(resource);}}
  static void Destroy(Package resource){foreach(var mesh in resource.meshes)if(mesh)Geometry.Release(mesh);foreach(var group in resource.materials)if(group!=null)foreach(var material in group)if(material)Geometry.Release(material);}
  public static Vector3 V(JToken value)=>AssemblyData.V(value.ToObject<float[]>());
  public static Quaternion Q(JToken value){var q=value.ToObject<float[]>();return new Quaternion(q[0],q[1],q[2],q[3]);}
 }

 public class ImportedRackPart:MonoBehaviour {
  public bool Ready {get;private set;}public string Error {get;private set;}public event Action Changed;
  string package;bool acquired,destroyed,selected;readonly List<Renderer> renderers=new();
  MaterialPropertyBlock properties;
  public async void Initialize(PartData part,AssemblyVisual owner){
   package=part.assetPackage;
   try{
    var resource=await RackResources.Acquire(package);acquired=true;if(destroyed){RackResources.Release(package);acquired=false;return;}
    var parentOffset=Vector3.zero;if(package!="exterior")parentOffset=RackResources.V(RackResources.Catalog["serverPositions"][part.parentPartId]);
    var instances=((JArray)resource.definition["instances"]).Where(i=>(string)i["part"]==part.assetPart).ToArray();if(instances.Length==0)throw new Exception("Source part mapping unavailable");
    foreach(var instance in instances){
     var child=new GameObject(part.name+" source mesh");child.transform.SetParent(transform,false);child.transform.localPosition=RackResources.V(instance["position"])+parentOffset;child.transform.localRotation=RackResources.Q(instance["rotation"]);child.transform.localScale=RackResources.V(instance["scale"]);
     int index=(int)instance["mesh"];child.AddComponent<MeshFilter>().sharedMesh=resource.meshes[index];var renderer=child.AddComponent<MeshRenderer>();renderer.sharedMaterials=resource.materials[index];renderer.shadowCastingMode=ShadowCastingMode.Off;renderers.Add(renderer);
    }
    // One bounded collider per selectable component. The enclosing rack frame must not occlude server hits.
    if(part.assetPart!="rack01.frame"){
     var primitive=part.primitives[0];var hit=new GameObject(part.name+" selection");hit.transform.SetParent(transform,false);var collider=hit.AddComponent<BoxCollider>();collider.center=AssemblyData.V(primitive.position);collider.size=AssemblyData.V(primitive.size);
     var handle=hit.AddComponent<PartHandle>();handle.Owner=owner;handle.Part=part;
    }else{
     // Thin side/top/bottom hit volumes leave the rack opening clear for server selection.
     var primitive=part.primitives[0];var center=AssemblyData.V(primitive.position);var size=AssemblyData.V(primitive.size);float thickness=.014f;
     for(int edge=0;edge<4;edge++){bool side=edge<2;float sign=edge%2==0?-1:1;var hit=new GameObject("Rack frame selection");hit.transform.SetParent(transform,false);var collider=hit.AddComponent<BoxCollider>();collider.center=center+(side?Vector3.right:Vector3.up)*sign*((side?size.x:size.y)-thickness)*.5f;collider.size=side?new Vector3(thickness,size.y,size.z):new Vector3(size.x,thickness,size.z);var handle=hit.AddComponent<PartHandle>();handle.Owner=owner;handle.Part=part;}
    }
    Ready=true;Highlight(selected);Changed?.Invoke();
   }catch(Exception error){if(!destroyed){Error=error.Message;Debug.LogWarning("Rack part: "+Error);Changed?.Invoke();}}
  }
  public void Highlight(bool value){selected=value;properties??=new MaterialPropertyBlock();properties.Clear();properties.SetColor("_EmissionColor",value?new Color(.12f,.085f,.02f):Color.black);foreach(var renderer in renderers)if(renderer)renderer.SetPropertyBlock(properties);}
  public void Release(){destroyed=true;if(acquired){RackResources.Release(package);acquired=false;}}
  void OnDestroy(){Release();}
 }
}
