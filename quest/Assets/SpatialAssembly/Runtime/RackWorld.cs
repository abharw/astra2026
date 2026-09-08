using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace SpatialAssembly {
 public class RackWorld:MonoBehaviour {
  public const string DefaultId="authored-rack-default-v1";
  public QuestAssemblyController Controller;
  public bool Loading {get;private set;}
  public bool IsDetailLoading=>pendingDetails.Count>0;
  public string Status {get;private set;}="Loading rack catalog…";
  int epoch,demoEpoch;public bool DemoPlaying {get;private set;}
  readonly HashSet<string> pendingDetails=new();
  async void Start(){
   try{
    await RackResources.EnsureCatalog();RackResources.ConfigureLighting();Controller.PublishScene();
    if(PlayerPrefs.GetInt("RackDefaultDeleted",0)==1)return;
    // Store.Start reads records synchronously. A saved but unlocalized rack must stay hidden.
    await Task.Yield();if(Controller.Store.SavedObjectIds.Contains(DefaultId)){Status="Restoring saved rack anchor";return;}
    Loading=true;
    while(this&&(!OVRManager.isHmdPresent||!OVRManager.hasVrFocus||Controller.Rig.centerEyeAnchor.position.y-Controller.Rig.trackingSpace.position.y<.3f))await Task.Yield();
    if(!this)return;
    var resource=await RackResources.Acquire("exterior");
    try{
     if(!this||Controller.Store.SavedObjectIds.Contains(DefaultId))return;
     var head=Controller.Rig.centerEyeAnchor;var forward=Vector3.ProjectOnPlane(head.forward,Vector3.up).normalized;
     if(forward.sqrMagnitude<.5f)forward=Vector3.forward;
     float height=(float)RackResources.Catalog["height"];var location=head.position+forward*2.1f+Vector3.Cross(Vector3.up,forward)*.35f;
     location.y=Controller.Rig.trackingSpace.position.y+height*.5f;
     var anchor=new GameObject("Authored rack world anchor");anchor.transform.SetPositionAndRotation(location,Quaternion.LookRotation(-forward,Vector3.up));anchor.AddComponent<OVRSpatialAnchor>();
     var child=new GameObject("Open Rack V2 · source-derived");child.transform.SetParent(anchor.transform,false);child.transform.localScale=Vector3.one*height;
     var visual=child.AddComponent<AssemblyVisual>();visual.ObjectId=DefaultId;visual.HomeScale=child.transform.localScale;visual.Build(CreateAssembly());
     Controller.RegisterAuthored(visual);Status="Rack ready · select a server, Y loads its parts";
    }finally{RackResources.Release("exterior");}
   }catch(Exception error){Status="Rack unavailable: "+error.Message;Debug.LogWarning(Status);}finally{Loading=false;if(Controller)Controller.Status=Status;}
  }
  public static AssemblyData CreateAssembly(){
   var catalog=RackResources.Catalog;var data=new AssemblyData{assetId=RackResources.AssetId,name="Open Rack V2 · 18 Barreleye G2 servers",description="Authored virtual rack from the approved source CAD. Select a server and load its processor, memory, fans, storage, power or other teaching groups on demand. This is not a reconstruction of the room.",confidence="high",revision=1,captureId="authored-source",sizeMeters=catalog["sizeMeters"].ToObject<float[]>(),bounds=new[]{0f,0f,1f,1f},parts=new List<PartData>(),research=new ResearchData{status="authored_source",summary="Source-derived exterior and teaching groups from the supplied Open Rack / Barreleye G2 library.",gaps=catalog["limits"].ToObject<string[]>(),sources=new List<SourceData>{new SourceData{id="rack-source",title="Open Rack / Barreleye G2 source library",url="https://github.com/abharw/astra2026/tree/051c9d954292438fc8419661aa91451367961d86/datacenter-rack",match="exact",kind="source_cad",findings="Authored reference CAD, not a measurement of live equipment."},new SourceData{id="teaching-source",title="Approved internal teaching groups and provenance",url="https://github.com/abharw/astra2026/blob/ef10dcbd5160b05205d61f5080a31ef117cfa900/assets/imported-rack/teaching-groups.json",match="exact",kind="source_cad",findings="Simplified source-derived assemblies; RDIMM modules are supported-class analogues."}}}};
   foreach(var source in (JArray)catalog["parts"]){string id=(string)source["partID"];var p=CreatePart(id,(string)source["name"],id=="rack01.frame"?"Supports 18 server instances and rack power equipment.":"Server instance with nine available teaching groups. Use load_asset_detail to open any group directly; available and loaded groups are listed separately in scene context.","exterior",id,null,"documented");p.isHousing=id!="rack01.frame";data.parts.Add(p);}return data;
  }
  static PartData CreatePart(string id,string name,string description,string package,string sourcePart,string parent,string evidence){
   var b=(JArray)RackResources.Catalog["packages"][package]["bounds"][sourcePart];var low=RackResources.V(b[0]);var high=RackResources.V(b[1]);var offset=parent==null?Vector3.zero:RackResources.V(RackResources.Catalog["serverPositions"][parent]);var center=(low+high)*.5f+offset;var size=high-low;
   return new PartData{id=id,name=name,description=description,function=description,evidence=evidence,uncertainty=evidence=="inferred"?"Supported-class or reconstructed appearance; exact installed specification is not established.":"Source-derived teaching geometry; no live measurement or simulation.",sourceIds=new[]{package=="exterior"?"rack-source":"teaching-source"},assetPackage=package,assetPart=sourcePart,parentPartId=parent,detailLevel=parent==null?0:1,isInternal=parent!=null,explode=DetailExplosion(package,center-offset),primitives=new List<PrimitiveData>{new PrimitiveData{kind="box",position=new[]{center.x,center.y,center.z},size=new[]{Mathf.Max(size.x,.001f),Mathf.Max(size.y,.001f),Mathf.Max(size.z,.001f)},rotation=new float[3],color=new[]{.6f,.6f,.6f},vertices=new List<float[]>(),triangles=Array.Empty<int>()}}};
  }
  static float[] DetailExplosion(string package,Vector3 localCenter){
   // A separated 3-by-3 teaching layout, in the rack's normalized coordinates.
   // Subtract each source center so differently sized groups share clear slots.
   string[] order={"storage","fanwall","power","processors","heatsinks","memory","network","motherboard","chassis"};
   int index=Array.IndexOf(order,package);if(index<0)return new[]{0f,0f,0f};
   var target=new Vector3((index%3-1)*.36f,(1-index/3)*.23f,.18f);
   var delta=target-localCenter;return new[]{delta.x,delta.y,delta.z};
  }
  public JObject Available(){
   if(RackResources.Catalog==null)return null;
   var rack=Controller.Objects.FirstOrDefault(o=>o.IsImportedRack);
   return new JObject{{"object_id",rack?.ObjectId??DefaultId},{"available",rack!=null},{"name","Authored data-center rack"},{"servers",new JArray(((JObject)RackResources.Catalog["serverPositions"]).Properties().Select(p=>p.Name))},{"groups",RackResources.Catalog["groups"].DeepClone()},{"loaded",new JArray(rack?.Data.parts.Where(p=>p.isInternal).Select(p=>p.id)??Array.Empty<string>())},{"visible",rack?.InternalsRevealed??false},{"limits",RackResources.Catalog["limits"].DeepClone()},{"instruction","Use load_asset_detail with server ID and group ID, or all. Groups are available from the beginning, but their meshes load only when requested. unload_asset_detail removes that server's requested group. Do not regenerate authored rack CAD to reveal existing parts."}};
  }
  public void Cancel(){epoch++;demoEpoch++;DemoPlaying=false;Status="Rack demo / loading cancelled";}
  public static AssemblyData DetailPatch(AssemblyData original,string server,string group,bool unload=false){
   var next=JsonConvert.DeserializeObject<AssemblyData>(JsonConvert.SerializeObject(original));
   if(RackResources.Catalog["serverPositions"][server]==null)throw new Exception("Unknown server");
   var definitions=((JArray)RackResources.Catalog["groups"]).Where(g=>group=="all"||(string)g["id"]==group).ToArray();if(definitions.Length==0)throw new Exception("Unknown detail group");
   foreach(var definition in definitions){string key=(string)definition["id"],id=server+".detail."+key;
    if(unload){next.parts.RemoveAll(p=>p.id==id);continue;}if(next.parts.Any(p=>p.id==id))continue;
    string evidence=(string)definition["representation"]=="cad_derived"?"documented":"inferred";
    next.parts.Add(CreatePart(id,(string)definition["name"],(string)definition["description"],key,key,server,evidence));
   }next.revision++;next.Validate();return next;
  }
  public async Task<(bool ok,string message)> LoadDetail(string objectId,string server,string group,bool unload=false,bool focus=true,bool select=true,bool reveal=true){
   var visual=Controller.Objects.FirstOrDefault(v=>v.ObjectId==objectId&&v.IsImportedRack);
   if(!visual)return(false,"The authored rack is not available or its anchor is not localized");
   await RackResources.EnsureCatalog();
   if(string.IsNullOrWhiteSpace(server))server=Controller.SelectedPart;
   if(server!=null&&server.Contains(".detail."))server=server.Split(new[]{".detail."},StringSplitOptions.None)[0];
   if(server==null||RackResources.Catalog["serverPositions"][server]==null)return(false,"Select or name an existing rack server first");
   if(string.IsNullOrWhiteSpace(group))group="all";
   var definitions=((JArray)RackResources.Catalog["groups"]).Where(g=>group=="all"||(string)g["id"]==group).ToArray();
   if(definitions.Length==0)return(false,"That part is not in the approved detail catalog");
   // Serialize changes to one server, while other servers and ordinary reconstruction remain independent.
   if(!pendingDetails.Add(server))return(false,"That server already has a detail request in progress");
   int admittedEpoch=epoch;int selection=Controller.ControlVersion;var held=new List<string>();
   try{
    Status=unload?"Closing server detail…":"Loading source parts…";
    Controller.PublishScene();
    // Prepare current resources too: a restored model can still be loading its exterior.
    foreach(string key in visual.Data.parts.Select(p=>p.assetPackage).Where(p=>!string.IsNullOrEmpty(p)).Distinct()){await RackResources.Acquire(key);held.Add(key);if(!this||admittedEpoch!=epoch)return(false,"Rack loading cancelled");}
    if(!unload)foreach(var definition in definitions){string key=(string)definition["id"];await RackResources.Acquire(key);held.Add(key);if(!this||admittedEpoch!=epoch)return(false,"Rack loading cancelled");}
    visual=Controller.Objects.FirstOrDefault(v=>v.ObjectId==objectId&&v.IsImportedRack);if(!visual)return(false,"Rack was removed while loading");
    if(selection!=Controller.ControlVersion)return(false,"User selection changed while loading; request the part again");
    var next=DetailPatch(visual.Data,server,group,unload);
    var replacement=Controller.ReplaceAuthored(visual,next);replacement.InternalsRevealed=reveal?(!unload||next.parts.Any(p=>p.isInternal)):visual.InternalsRevealed;replacement.ShowInferred=true;replacement.Restyle();
    string selected=unload?server:group=="all"?server:server+".detail."+group;
    if(!unload&&focus)replacement.FocusPart(selected,Controller.Rig.centerEyeAnchor);
    if(select)Controller.SelectAuthoredPart(replacement,selected);else Controller.PublishScene();Controller.Store.SaveCurrent();
    Status=unload?"Source detail unloaded":"Source detail loaded · "+(group=="all"?"nine groups":group);
    return(true,Status);
   }catch(Exception error){Status="Rack detail unavailable: "+error.Message;return(false,Status);}
   finally{pendingDetails.Remove(server);foreach(var key in held)RackResources.Release(key);if(Controller){Controller.Status=Status;Controller.PublishScene();}}
  }
  public async Task PlayDemo(){
   if(DemoPlaying){Cancel();return;}
   var initial=Controller.Active;if(!initial||!initial.IsImportedRack)return;
   if(IsDetailLoading){Controller.Status="Wait for the current part load or press Y to cancel";return;}
   int run=++demoEpoch;DemoPlaying=true;
   try{
    await RackResources.EnsureCatalog();if(!this||run!=demoEpoch)return;
    string objectId=initial.ObjectId;string server=Controller.SelectedPart?.Split(new[]{".detail."},StringSplitOptions.None)[0];
    var head=Controller.Rig.centerEyeAnchor;
    if(server==null||RackResources.Catalog["serverPositions"][server]==null){
     server=initial.Data.parts.Where(p=>RackResources.Catalog["serverPositions"][p.id]!=null).OrderBy(p=>(initial.PartWorldCenter(p.id)-(head.position+head.forward*1.5f-head.up*.2f)).sqrMagnitude).First().id;
    }
    Controller.Bridge.Send(new JObject{{"type","walkthrough.cancel"}});Controller.Audio.InterruptPlayback();
    string selectedComponent=Controller.SelectedPart;
    if(initial.Data.parts.Any(p=>p.id==selectedComponent&&p.isInternal)){
     initial.FocusPart(selectedComponent,head);Controller.SelectAuthoredPart(initial,selectedComponent);Controller.Store.SaveCurrent();
     await NarrateDemo(objectId,server,new[]{selectedComponent},run,Controller.ControlVersion);return;
    }
    initial.CloseHousing();Controller.SelectAuthoredPart(initial,server);int selection=Controller.ControlVersion;
    bool Current()=>this&&run==demoEpoch&&Controller.Active&&Controller.Active.ObjectId==objectId&&Controller.ControlVersion==selection;
    AssemblyVisual Visual()=>Controller.Objects.FirstOrDefault(v=>v.ObjectId==objectId);
    var source=initial.PartWorldCenter(server);var slide=source+initial.transform.forward*.4f;var view=head.position+head.forward*1.25f-head.up*.22f;
    Status="Pulling server into view";Controller.Status=Status;
    // Start local asset loading during the visible pull-out, but retain the housing until the slide finishes.
    var loading=LoadDetail(objectId,server,"all",focus:false,select:false,reveal:false);
    float start=Time.realtimeSinceStartup;
    while(Time.realtimeSinceStartup-start<.85f){
     if(!Current()){await loading;return;}float t=Time.realtimeSinceStartup-start;
     var location=t<.35f?Vector3.Lerp(source,slide,Mathf.SmoothStep(0,1,t/.35f)):Vector3.Lerp(slide,view,Mathf.SmoothStep(0,1,(t-.35f)/.5f));
     var visual=Visual();if(!visual){await loading;return;}visual.FocusPartAtWorld(server,location,false);await Task.Yield();
    }
    if(!Current()){await loading;return;}Visual().FocusPartAtWorld(server,view,false);
    var loaded=await loading;if(!Current())return;if(!loaded.ok){Status=loaded.message;return;}
    var ready=Visual();if(!ready)return;ready.FocusPartAtWorld(server,view);ready.SetExplosion(.2f);
    Status="Opening server components";Controller.Status=Status;start=Time.realtimeSinceStartup;
    while(Time.realtimeSinceStartup-start<.8f){if(!Current())return;ready.SetExplosion(Mathf.Lerp(.2f,1,Mathf.SmoothStep(0,1,(Time.realtimeSinceStartup-start)/.8f)));await Task.Yield();}
    if(!Current())return;ready.SetExplosion(1);ready.RememberInspectionLayout();
    string[] order={"processors","memory","motherboard","storage","network","power","fanwall","heatsinks","chassis"};
    var ids=order.Select(id=>server+".detail."+id).Where(id=>ready.Data.parts.Any(p=>p.id==id)).ToArray();
    start=Time.realtimeSinceStartup;while(Time.realtimeSinceStartup-start<.45f){if(!Current())return;await Task.Yield();}
    // The first component comes forward locally even when voice is offline.
    ready.FocusPart(ids[0],head);Controller.SelectAuthoredPart(ready,ids[0]);selection=Controller.ControlVersion;Controller.Store.SaveCurrent();
    await NarrateDemo(objectId,server,ids,run,selection);
   }catch(Exception error){Status="Rack demo unavailable: "+error.Message;Debug.LogWarning(Status);}
   finally{if(this&&run==demoEpoch){DemoPlaying=false;Controller.Status=Status;Controller.PublishScene();}}
  }
  async Task NarrateDemo(string objectId,string server,string[] ids,int run,int selection){
   bool Current()=>this&&run==demoEpoch&&Controller.Active&&Controller.Active.ObjectId==objectId&&Controller.ControlVersion==selection;
   Status="Components ready · hold B for voice";Controller.Status=Status;if(!Controller.Bridge.Connected)return;
   if(!Controller.Audio.Enabled&&!Controller.Audio.Starting&&!Controller.Audio.AwaitingPermission)Controller.Audio.Toggle();
   float start=Time.realtimeSinceStartup;
   while(!Controller.Audio.Enabled){if(!Current()||Time.realtimeSinceStartup-start>30||(!Controller.Audio.Starting&&!Controller.Audio.AwaitingPermission))return;await Task.Yield();}
   if(!Current())return;Controller.PublishScene();Controller.Bridge.Send(new JObject{{"type","walkthrough.start"},{"object_id",objectId},{"selection_version",selection},{"server",server},{"parts",new JArray(ids)}});Status="Explaining server components";
  }
  void OnDestroy(){epoch++;demoEpoch++;}

 }
}
