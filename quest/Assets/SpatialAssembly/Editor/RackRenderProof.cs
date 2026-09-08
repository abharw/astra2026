using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Newtonsoft.Json;
using SpatialAssembly;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

// Native Unity import/render proof. Does not connect to or control a headset or bridge.
public static class RackRenderProof {
 static string output;
 public static async void Run(){
  try{
   ShaderUtil.allowAsyncCompilation=false;
   output=Environment.GetEnvironmentVariable("RACK_PROOF_DIR")??Path.GetFullPath("../rack-proof");Directory.CreateDirectory(output);
   EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
   await RackResources.EnsureCatalog();RackResources.ConfigureLighting();
   RenderSettings.ambientMode=AmbientMode.Flat;RenderSettings.ambientLight=new Color(.46f,.49f,.54f);
   var light=new GameObject("Key light").AddComponent<Light>();light.type=LightType.Directional;light.intensity=1.3f;light.transform.rotation=Quaternion.Euler(42,-28,0);
   var fill=new GameObject("Fill light").AddComponent<Light>();fill.type=LightType.Directional;fill.intensity=.5f;fill.transform.rotation=Quaternion.Euler(20,145,0);
   var floor=GameObject.CreatePrimitive(PrimitiveType.Cube);floor.name="Preview floor";floor.transform.localScale=new Vector3(7,.03f,7);floor.transform.position=new Vector3(0,-1.12f,0);floor.GetComponent<Renderer>().sharedMaterial=new Material(Shader.Find("Standard")){color=new Color(.14f,.16f,.19f)};
   var camera=new GameObject("Proof camera").AddComponent<Camera>();camera.clearFlags=CameraClearFlags.SolidColor;camera.backgroundColor=new Color(.07f,.085f,.11f);camera.fieldOfView=38;camera.nearClipPlane=.02f;camera.farClipPlane=20;
   var data=RackWorld.CreateAssembly();var rack=await Visual(data);
   if(RackResources.LoadedPackages.Any(p=>p!="exterior"))throw new Exception("Detail loaded before a request");
   Capture(camera,new Vector3(2.6f,1.1f,4.1f),new Vector3(0,0,0),"rack-exterior.png");
   var before=data.parts.Select(p=>p.id).ToArray();var processor=RackWorld.DetailPatch(data,"rack01.server03","processors");
   if(processor.parts.Count!=20||!before.All(id=>processor.parts.Any(p=>p.id==id)))throw new Exception("Direct detail patch damaged exterior identities");
   rack.ReleaseImportedAssets();UnityEngine.Object.DestroyImmediate(rack.gameObject);rack=await Visual(processor);rack.InternalsRevealed=true;
   var head=new GameObject("Preview viewer").transform;head.position=new Vector3(0,.4f,3);
   rack.FocusPart("rack01.server03.detail.processors",head);rack.SettleInspectionForPreview();
   if(RackResources.LoadedPackages.Any(p=>p!="exterior"&&p!="processors"))throw new Exception("A direct processor request loaded unrelated parts");
   Capture(camera,new Vector3(.42f,.6f,1.95f),new Vector3(0,.16f,1.2f),"rack-processors-direct.png");
   var full=RackWorld.DetailPatch(processor,"rack01.server03","all");rack.ReleaseImportedAssets();UnityEngine.Object.DestroyImmediate(rack.gameObject);rack=await Visual(full);rack.InternalsRevealed=true;rack.FocusPart("rack01.server03",head);rack.SettleInspectionForPreview();
   Capture(camera,new Vector3(1.15f,1.0f,2.85f),new Vector3(0,.1f,1.1f),"rack-server-interior.png");
   var unloaded=RackWorld.DetailPatch(full,"rack01.server03","all",true);if(unloaded.parts.Count!=19)throw new Exception("Unload did not restore exterior identities");
   rack.ReleaseImportedAssets();UnityEngine.Object.DestroyImmediate(rack.gameObject);rack=await Visual(unloaded);
   if(RackResources.LoadedPackages.Any(p=>p!="exterior"))throw new Exception("Unused detail resources were retained after unload");
   File.WriteAllText(Path.Combine(output,"native-render-proof.json"),JsonConvert.SerializeObject(new{status="passed",renderer="Unity editor; no headset or bridge",initialParts=19,directProcessorParts=20,fullInteriorParts=28,afterUnloadParts=19,loadedAfterUnload=RackResources.LoadedPackages.ToArray(),sourceHeightMeters=2.21,images=new[]{"rack-exterior.png","rack-processors-direct.png","rack-server-interior.png"}},Formatting.Indented));
   Debug.Log("RACK_NATIVE_RENDER_PROOF "+output);EditorApplication.Exit(0);
  }catch(Exception error){Debug.LogException(error);EditorApplication.Exit(1);}
 }
 // Preview the production transforms with another server already loaded, as in a reused scene.
 public static async void Sequence(){
  try{
   ShaderUtil.allowAsyncCompilation=false;output=Environment.GetEnvironmentVariable("RACK_PROOF_DIR")??Path.GetFullPath("../rack-sequence-preview");Directory.CreateDirectory(output);
   EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);await RackResources.EnsureCatalog();RackResources.ConfigureLighting();
   RenderSettings.ambientMode=AmbientMode.Flat;RenderSettings.ambientLight=new Color(.46f,.49f,.54f);
   var light=new GameObject("Key light").AddComponent<Light>();light.type=LightType.Directional;light.intensity=1.3f;light.transform.rotation=Quaternion.Euler(42,-28,0);
   var fill=new GameObject("Fill light").AddComponent<Light>();fill.type=LightType.Directional;fill.intensity=.5f;fill.transform.rotation=Quaternion.Euler(20,145,0);
   var camera=new GameObject("Preview camera").AddComponent<Camera>();camera.clearFlags=CameraClearFlags.SolidColor;camera.backgroundColor=new Color(.07f,.085f,.11f);camera.fieldOfView=48;camera.nearClipPlane=.02f;camera.farClipPlane=20;
   const string server="rack01.server03";var data=RackWorld.DetailPatch(RackWorld.DetailPatch(RackWorld.CreateAssembly(),"rack01.server14","all"),server,"all");var rack=await Visual(data);
   var head=new GameObject("Wearer position").transform;head.position=new Vector3(0,.55f,2.4f);head.rotation=Quaternion.LookRotation(Vector3.back,Vector3.up);
   rack.BeginServerInspection(server);rack.SettleInspectionForPreview();var path=RackWorld.ServerPullPositions(rack,server,head);
   Capture(camera,new Vector3(2.6f,1.1f,4.1f),new Vector3(0,0,.45f),"01-closed-in-rack.png");
   rack.FocusPartAtWorld(server,path.slide,false,true);rack.SettleInspectionForPreview();Capture(camera,new Vector3(2.6f,1.1f,4.1f),new Vector3(0,0,.45f),"02-chassis-clear.png");
   rack.FocusPartAtWorld(server,path.view,false,true);rack.SettleInspectionForPreview();Capture(camera,new Vector3(2.6f,1.1f,4.1f),new Vector3(0,0,.45f),"03-closed-in-view.png");
   var targets=rack.ServerInspectionTargets(server,path.view,head.right);rack.StageServerInternals(server,path.view,targets,1);rack.RememberInspectionLayout();rack.SettleInspectionForPreview();
   Capture(camera,new Vector3(2.6f,1.1f,4.1f),new Vector3(0,0,.45f),"04-internals-above-chassis.png");camera.fieldOfView=80;Capture(camera,head.position,new Vector3(0,.1f,1.25f),"05-wearer-view.png");
   File.WriteAllText(Path.Combine(output,"sequence-preview.json"),JsonConvert.SerializeObject(new{status="rendered",renderer="Unity editor; no headset or bridge",selectedServer=server,previouslyLoadedServer="rack01.server14",source=path.source.ToString("F4"),clear=path.slide.ToString("F4"),view=path.view.ToString("F4"),liftedGroups=targets.Keys.ToArray(),chassisStaysAtSourceRelativeOffset=true},Formatting.Indented));
   Debug.Log("RACK_SEQUENCE_PREVIEW "+output);EditorApplication.Exit(0);
  }catch(Exception error){Debug.LogException(error);EditorApplication.Exit(1);}
 }
 static async Task<AssemblyVisual> Visual(AssemblyData data){var root=new GameObject(data.name);root.transform.localScale=Vector3.one*2.21f;var v=root.AddComponent<AssemblyVisual>();v.Build(data);double until=EditorApplication.timeSinceStartup+90;
  while(!v.AssetsReady){if(v.AssetError!=null)throw new Exception(v.AssetError);if(EditorApplication.timeSinceStartup>until)throw new Exception("Native asset preparation timed out");await Task.Yield();}v.Restyle();return v;}
 static void Capture(Camera camera,Vector3 position,Vector3 target,string filename){camera.transform.position=position;camera.transform.LookAt(target);var rt=new RenderTexture(1440,1440,24,RenderTextureFormat.ARGB32,RenderTextureReadWrite.sRGB);var image=new Texture2D(1440,1440,TextureFormat.RGB24,false);try{camera.targetTexture=rt;camera.Render();RenderTexture.active=rt;image.ReadPixels(new Rect(0,0,1440,1440),0,0);image.Apply();File.WriteAllBytes(Path.Combine(output,filename),image.EncodeToPNG());}finally{RenderTexture.active=null;camera.targetTexture=null;UnityEngine.Object.DestroyImmediate(rt);UnityEngine.Object.DestroyImmediate(image);}}
}
