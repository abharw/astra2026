using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using Meta.XR;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.UI;

namespace SpatialAssembly {
 public class QuestAssemblyController:MonoBehaviour {
  public OVRCameraRig Rig;public OVRHand RightHand;public PassthroughCameraAccess CameraAccess;public EnvironmentRaycastManager Depth;
  public QuestTestControl TestControl;public BridgeConnection Bridge;public RealtimeAudio Audio;public SavedAssemblies Store;
  public RackWorld Rack;public int ControlVersion=>selectionVersion;
  public void PublishScene()=>SyncScene();
  public void RegisterAuthored(AssemblyVisual visual){objects.Add(visual);if(!Active&&!grabbed){Active=visual;selectionVersion++;}Store.Register(visual);SyncScene();}
  public AssemblyVisual ReplaceAuthored(AssemblyVisual old,AssemblyData data){ReplaceObject(old,data);return objects.First(v=>v.ObjectId==old.ObjectId);}
  public void SelectAuthoredPart(AssemblyVisual visual,string part){selectionVersion++;pointedTargetLocked=false;Active=visual;selectedPart=part;visual.Select(part);var p=visual.Data.parts.FirstOrDefault(p=>p.id==part);if(p!=null)ShowPart(p);SyncScene();}
  async void LoadSelectedRack(){var result=await Rack.LoadDetail(Active.ObjectId,selectedPart,"all");Status=result.message;}
  async void AssetCommand(JObject e){
   (bool ok,string message) result;
   try{if((int?)e["selection_version"]!=selectionVersion)result=(false,"User interaction superseded this command");else if(!Rack)result=(false,"Rack loader unavailable");else result=await Rack.LoadDetail((string)e["object_id"],(string)e["server"],(string)e["part"],(string)e["action"]=="unload_asset_detail");}
   catch(Exception error){result=(false,error.Message);}
   if(!this)return;SyncScene();Bridge.Send(new JObject{{"type","command.result"},{"call_id",e["call_id"]},{"ok",result.ok},{"message",result.message}});
  }
  public Text StatusText,DetailText,HintText,VoiceButton,PullButton;public Transform Panel;
  AssemblyVisual grabbed;Vector3 grabOffset,desiredGrabOffset,grabVelocity,desiredGrabScale;Quaternion grabRotation;bool grabByPinch,lastGrip;
  bool waitForGripRelease;bool panelFollows=true;string voiceCaption="";
  public bool Busy=>jobs.Count>0;public int RunningJobs=>jobs.Count;public string SelectedPart=>selectedPart;public IEnumerable<AssemblyVisual> Objects=>objects.Where(v=>v);
  public string Status="Allow camera and spatial-data permissions. Point at an object.";
  public AssemblyVisual Active;readonly List<AssemblyVisual> objects=new();
  bool pointedTargetLocked;Vector3 lockedTarget,lockedNormal;
  const int MaxJobs=4;
  class ReconstructionJob {public string id,objectId,partId,stage;public bool refine;public Snapshot capture;public float started;public int selectionVersion,number,epoch;public Transform marker;public TextMesh label;}
  readonly Dictionary<string,ReconstructionJob> jobs=new();int selectionVersion,jobNumber,generationEpoch;readonly HashSet<string> cancelledJobs=new();
  Transform marker;LineRenderer pointer;bool lastPinch;Vector3 target,normal;bool hasTarget;string selectedPart;int explainIndex;
  bool busy=>Busy;
  float OldestStart=>jobs.Count>0?jobs.Values.Min(j=>j.started):Time.realtimeSinceStartup;
  public class Snapshot {
   public Pose camera;public Vector3 target,normal,ray00,ray10,ray01,ray11;
   public Ray Ray(float x,float y){var direction=Vector3.Lerp(Vector3.Lerp(ray00,ray10,x),Vector3.Lerp(ray01,ray11,x),y);return new Ray(camera.position,camera.rotation*direction.normalized);}
  }
  IEnumerator Start(){
   Bridge.Message+=OnMessage;Store.Restored+=v=>{objects.Add(v);if(!grabbed){Active=v;selectedPart=null;pointedTargetLocked=false;}SyncScene();};Audio.Bridge=Bridge;
   var dot=GameObject.CreatePrimitive(PrimitiveType.Sphere);Destroy(dot.GetComponent<Collider>());marker=dot.transform;marker.localScale=Vector3.one*.016f;dot.GetComponent<Renderer>().material=new Material(Shader.Find("Unlit/Color"));dot.GetComponent<Renderer>().material.color=Color.cyan;
   pointer=new GameObject("Pointing ray").AddComponent<LineRenderer>();pointer.positionCount=2;pointer.startWidth=.002f;pointer.endWidth=.001f;pointer.material=new Material(Shader.Find("Unlit/Color"));pointer.material.color=Color.cyan;
   OVRPermissionsRequester.Request(new[]{OVRPermissionsRequester.Permission.PassthroughCameraAccess,OVRPermissionsRequester.Permission.Scene});
   while(!CameraAccess.IsPlaying){Status="Waiting for passthrough camera permission / camera feed";yield return null;}
   Status="Point with your hand or controller. Trigger selects. Right stick click confirms a scan.";PositionPanel();
  }
  bool HandPointerAvailable()=>RightHand&&RightHand.IsTracked&&RightHand.IsPointerPoseValid&&RightHand.HandConfidence==OVRHand.TrackingConfidence.High;
  bool UsingHandPointer()=>HandPointerAvailable()&&(OVRInput.GetActiveController()&OVRInput.Controller.Touch)==0;
  Ray PointingRay(){var t=UsingHandPointer()?RightHand.PointerPose:Rig.rightControllerAnchor;return new Ray(t.position,t.forward);}
  Pose HandPose(){var t=grabbed?(grabByPinch?RightHand.PointerPose:Rig.rightControllerAnchor):(UsingHandPointer()?RightHand.PointerPose:Rig.rightControllerAnchor);return new Pose(t.position,t.rotation);}
  void Update(){
   if(!Rig||!CameraAccess)return;
   if(panelFollows&&Panel&&Panel.gameObject.activeSelf)PlacePanelAtEyeHeight(false);
   foreach(var j in jobs.Values){if(!j.marker)continue;j.label.transform.rotation=Quaternion.LookRotation(j.label.transform.position-Rig.centerEyeAnchor.position,Vector3.up);j.label.text="Scan "+j.number+" • "+(int)(Time.realtimeSinceStartup-j.started)+"s\n"+j.stage;}
   var ray=PointingRay();EnvironmentRaycastHit hit=default;hasTarget=EnvironmentRaycastManager.IsSupported&&Depth.Raycast(ray,out hit,6);
   if(hasTarget){target=hit.point;normal=hit.normalConfidence>.3f?hit.normal:(Rig.centerEyeAnchor.position-target).normalized;}
   bool virtualHit=Physics.Raycast(ray,out var selected,6);var part=virtualHit?selected.collider.GetComponent<PartHandle>():null;
   if(marker){marker.gameObject.SetActive(hasTarget||part);marker.position=part?selected.point:target;}
   if(pointer){pointer.SetPosition(0,ray.origin);pointer.SetPosition(1,part?selected.point:hasTarget?target:ray.GetPoint(1));}
   bool pinch=UsingHandPointer()&&RightHand.GetFingerIsPinching(OVRHand.HandFinger.Index);
   bool grip=OVRInput.Get(OVRInput.Axis1D.PrimaryHandTrigger,OVRInput.Controller.RTouch)>.5f;
   bool gripDown=grip&&!lastGrip;lastGrip=grip;
   bool leftGrip=OVRInput.Get(OVRInput.Axis1D.PrimaryHandTrigger,OVRInput.Controller.LTouch)>.5f;
   bool pressed=(pinch&&!lastPinch)||OVRInput.GetDown(OVRInput.Button.PrimaryIndexTrigger,OVRInput.Controller.RTouch);lastPinch=pinch;
   if(OVRInput.GetDown(OVRInput.Button.PrimaryThumbstick,OVRInput.Controller.LTouch)){if(leftGrip)Store.Restore();else if(Panel){Panel.gameObject.SetActive(!Panel.gameObject.activeSelf);if(Panel.gameObject.activeSelf)PositionPanel();}}
   if(OVRInput.GetDown(OVRInput.Button.One,OVRInput.Controller.RTouch)&&Active){Bridge.Send(new JObject{{"type","walkthrough.cancel"}});selectionVersion++;if(leftGrip)BringToMe();else if(Active.Explosion>.05f)Active.CloseHousing();else Active.SetExplosion(1);SyncScene();}
   if(OVRInput.GetDown(OVRInput.Button.Two,OVRInput.Controller.RTouch)){if(leftGrip&&TestControl)TestControl.ToggleTest();else Audio.Toggle();}
   if(OVRInput.GetDown(OVRInput.Button.One,OVRInput.Controller.LTouch)){if(leftGrip)DeleteSelected();else ExplainNext();}
   if(OVRInput.GetDown(OVRInput.Button.Two,OVRInput.Controller.LTouch)){if(leftGrip||busy||(Rack&&Rack.IsDetailLoading))Cancel();else Refine();}
   if(OVRInput.GetDown(OVRInput.Button.PrimaryThumbstick,OVRInput.Controller.RTouch)){if(pointedTargetLocked){Reconstruct();}else ReturnSelected();}
   if(!grip&&!pinch)waitForGripRelease=false;
   if(grabbed){
    if(grabByPinch&&!HandPointerAvailable()){EndGrab();waitForGripRelease=true;UpdateStatus();return;}
    if(pressed&&!pinch&&hasTarget){PlaceActive(target,normal);waitForGripRelease=true;UpdateStatus();return;}
    if(grabByPinch?pinch:grip){
     var hand=HandPose();var stick=OVRInput.Get(OVRInput.Axis2D.PrimaryThumbstick,OVRInput.Controller.RTouch);
     float horizontal=StickValue(stick.x),vertical=StickValue(stick.y);
     if(leftGrip)grabRotation=Quaternion.AngleAxis(-vertical*90*Time.deltaTime,Vector3.right)*grabRotation;
     else desiredGrabOffset.z=Mathf.Clamp(desiredGrabOffset.z+vertical*Time.deltaTime*1.6f,.25f,5);
     var worldUpInHand=Quaternion.Inverse(hand.rotation)*Vector3.up;
     grabRotation=Quaternion.AngleAxis(horizontal*110*Time.deltaTime,worldUpInHand)*grabRotation;
     MoveGrab(hand,false);
    }else EndGrab();UpdateStatus();return;
   }
   if(!waitForGripRelease){
    var item=part?part.Owner:(!pointedTargetLocked?Active:null);
    if(item&&((part&&pinch&&pressed)||gripDown)){
     if(part)selectedPart=part.Part.id;grabByPinch=pinch;BeginGrab(item,HandPose());
     Active.Select(selectedPart);if(part)ShowPart(part.Part);UpdateStatus();return;
    }
   }
   if(pressed){Bridge.Send(new JObject{{"type","walkthrough.cancel"}});if(part){selectionVersion++;pointedTargetLocked=false;Active=part.Owner;selectedPart=part.Part.id;Active.Select(selectedPart);ShowPart(part.Part);SyncScene();}else if(hasTarget){LockPoint(target,normal);Status="Target selected • right stick click to scan, or explicitly ask to reconstruct";}}
   if(Active&&Active.Extracted){var stick=OVRInput.Get(OVRInput.Axis2D.PrimaryThumbstick,OVRInput.Controller.RTouch);if(!pointedTargetLocked){float x=StickValue(stick.x),y=StickValue(stick.y);if(x!=0||y!=0)Active.StopMotion();if(leftGrip)Active.transform.Rotate(Rig.centerEyeAnchor.right,-y*90*Time.deltaTime,Space.World);else Active.transform.position+=Rig.centerEyeAnchor.forward*y*Time.deltaTime*1.2f;Active.transform.Rotate(Vector3.up,x*110*Time.deltaTime,Space.World);}}
   UpdateStatus();
  }
  static float StickValue(float value)=>Mathf.Abs(value)<.18f?0:Mathf.Sign(value)*(Mathf.Abs(value)-.18f)/.82f;
  public void BeginGrab(AssemblyVisual item,Pose hand){Bridge.Send(new JObject{{"type","walkthrough.cancel"}});
   selectionVersion++;pointedTargetLocked=false;grabbed=item;Active=item;item.StopMotion();item.Extracted=true;grabVelocity=Vector3.zero;
   grabOffset=Quaternion.Inverse(hand.rotation)*(item.transform.position-hand.position);desiredGrabOffset=grabOffset;
   grabRotation=Quaternion.Inverse(hand.rotation)*item.transform.rotation;desiredGrabScale=item.transform.localScale;
   if(grabOffset.magnitude>1.05f){desiredGrabOffset=new Vector3(0,0,.6f);desiredGrabScale=item.InspectionScale(.65f);}
   Status="Holding • twist your wrist or use the stick to rotate";SyncScene();
  }
  public void MoveGrab(Pose hand,bool immediate){
   if(!grabbed)return;float blend=immediate?1:1-Mathf.Exp(-14*Time.deltaTime);
   grabOffset=Vector3.Lerp(grabOffset,desiredGrabOffset,blend);grabbed.transform.localScale=Vector3.Lerp(grabbed.transform.localScale,desiredGrabScale,blend);
   var position=hand.position+hand.rotation*grabOffset;
   grabbed.transform.position=immediate?position:Vector3.SmoothDamp(grabbed.transform.position,position,ref grabVelocity,.045f,12,Time.deltaTime);
   grabbed.transform.rotation=Quaternion.Slerp(grabbed.transform.rotation,hand.rotation*grabRotation,immediate?1:1-Mathf.Exp(-22*Time.deltaTime));
  }
  public void BringToMe(){selectionVersion++;if(!Active){Status="Trigger-select a generated item first";return;}if(grabbed){desiredGrabOffset=new Vector3(0,0,.6f);desiredGrabScale=grabbed.InspectionScale(.65f);}else Active.PullOut(Rig.centerEyeAnchor);pointedTargetLocked=false;Status="Bringing selected item within reach";SyncScene();Store.SaveCurrent();}
  public void EndGrab(){grabbed=null;grabVelocity=Vector3.zero;SyncScene();Store.SaveCurrent();}
  public void PlaceActive(Vector3 point,Vector3 surfaceNormal){selectionVersion++;if(grabbed)Active=grabbed;if(!Active)return;pointedTargetLocked=false;EndGrab();Active.Extracted=true;var size=AssemblyData.V(Active.Data.sizeMeters)/Active.Data.sizeMeters.Max();var scale=Active.transform.lossyScale;float support=(Mathf.Abs(Vector3.Dot(surfaceNormal,Active.transform.right))*size.x*scale.x+Mathf.Abs(Vector3.Dot(surfaceNormal,Active.transform.up))*size.y*scale.y+Mathf.Abs(Vector3.Dot(surfaceNormal,Active.transform.forward))*size.z*scale.z)*.5f;Active.transform.position=point+surfaceNormal*Mathf.Max(.01f,support);Status="Placed • grip to move again, or say return object";SyncScene();Store.SaveCurrent();}
  void UpdateStatus(){
   string state=!Bridge.Connected?"OFFLINE":!CameraAccess.IsPlaying?"CAMERA NOT READY":grabbed?"HOLDING OBJECT":Rack&&Rack.IsDetailLoading?"LOADING RACK PARTS":busy?"RECONSTRUCTING ×"+jobs.Count:pointedTargetLocked?"TARGET SELECTED":!string.IsNullOrEmpty(Audio.Error)?"VOICE ERROR":Audio.Speaking?"SPEAKING":Audio.Enabled?"LISTENING":Audio.Starting?"STARTING VOICE":"READY";
   string next=!Bridge.Connected?"Reconnecting automatically. Check Quest and Mac Wi-Fi.":!CameraAccess.IsPlaying?"Allow camera access in the headset.":grabbed?"Twist your wrist to rotate. Stick turns / moves closer. Release grip to drop.":Rack&&Rack.IsDetailLoading?"Loading the requested source parts. Y cancels.":busy?"Each scan has an amber marker. Confirm another target to add a job. Y cancels all.":pointedTargetLocked?"Right stick click confirms reconstruction. Trigger alone does not scan.":!string.IsNullOrEmpty(Audio.Error)?Audio.Error+" Press B to retry voice.":Audio.Speaking?"Reply is playing. Speak to interrupt or press B to stop voice.":Audio.Enabled?"Ask a question aloud. Your microphone is on.":Active?Active.Extracted?"Hold grip to bring the selected item to your hand. Stick turns it; right-stick click returns it.":"Trigger selects a part. Hold grip to bring it to you. A explodes.":hasTarget?"Trigger selects a target. Right stick click confirms the scan.":"Aim at a nearby real surface until the cyan target appears.";
   if(StatusText){StatusText.text=state+(busy?$"  •  {(int)(Time.realtimeSinceStartup-OldestStart)}s":"")+"\n"+next+"\n"+(busy?Status:pointedTargetLocked?"Target selected; awaiting your reconstruction request":Active?"Selected: "+Active.Data.name:Status);StatusText.color=!Bridge.Connected?new Color(1,.65f,.4f):Color.white;}
   if(HintText)HintText.text="Trigger selects • Grip brings / holds • Release drops\nTwist wrist to rotate • Stick: turn / near–far\nLeft grip + stick up/down: tilt • Left grip + A: bring here\nA: explode • B: voice • X: explain • Y: load rack parts / improve\nRight stick click: confirm scan / return selected item\nLeft grip + X: delete • Holding + trigger: place\nLeft stick click: hide guide • + left grip: restore";
   if(VoiceButton)VoiceButton.text=Audio.Enabled||Audio.Starting?"Stop voice":"Start voice";
   if(PullButton)PullButton.text=Active&&Active.Extracted?"Return object":"Pull object";
  }
  public void PositionPanel(){panelFollows=true;PlacePanelAtEyeHeight(true);}
  void PlacePanelAtEyeHeight(bool immediate){if(Panel&&Rig){var forward=Vector3.ProjectOnPlane(Rig.centerEyeAnchor.forward,Vector3.up);if(forward.sqrMagnitude<.01f)forward=Vector3.ProjectOnPlane(Rig.transform.forward,Vector3.up);forward.Normalize();var right=Vector3.Cross(Vector3.up,forward);var desired=Rig.centerEyeAnchor.position+forward*1.15f-right*.48f-Vector3.up*.13f;var rotation=Quaternion.LookRotation(desired-Rig.centerEyeAnchor.position,Vector3.up);if(immediate||Vector3.Distance(Panel.position,desired)>.12f||Quaternion.Angle(Panel.rotation,rotation)>12){float blend=immediate?1:1-Mathf.Exp(-7*Time.deltaTime);Panel.position=Vector3.Lerp(Panel.position,desired,blend);Panel.rotation=Quaternion.Slerp(Panel.rotation,rotation,blend);}}}
  ReconstructionJob AddJob(string id,string objectId,bool refine,Snapshot capture,Vector3 point){
   if(jobs.TryGetValue(id,out var existing))return existing;
   if(jobs.Count>=MaxJobs)throw new Exception("Four scans are running; wait for one to finish or press Y to cancel");
   var j=new ReconstructionJob{id=id,objectId=objectId,refine=refine,capture=capture,started=Time.realtimeSinceStartup,selectionVersion=selectionVersion,number=++jobNumber,epoch=generationEpoch,stage="Starting"};
   j.marker=GameObject.CreatePrimitive(PrimitiveType.Sphere).transform;j.marker.name="Scan "+j.number;Destroy(j.marker.GetComponent<Collider>());j.marker.position=point;j.marker.localScale=Vector3.one*.03f;
   var renderer=j.marker.GetComponent<Renderer>();renderer.material=new Material(Shader.Find("Unlit/Color"));renderer.material.color=new Color(1,.65f,.1f);
   j.label=new GameObject("Scan progress").AddComponent<TextMesh>();j.label.font=Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");j.label.GetComponent<Renderer>().sharedMaterial=j.label.font.material;j.label.fontSize=40;j.label.characterSize=.014f;j.label.anchor=TextAnchor.MiddleCenter;j.label.color=new Color(1,.8f,.3f);j.label.transform.position=point+Vector3.up*.08f;
   jobs[id]=j;return j;
  }
  void RemoveJob(string id){if(id==null||!jobs.TryGetValue(id,out var j))return;jobs.Remove(id);if(j.marker){Destroy(j.marker.GetComponent<Renderer>().material);Destroy(j.marker.gameObject);}if(j.label)Destroy(j.label.gameObject);}
  void ClearJobs(){foreach(var id in jobs.Keys.ToArray())RemoveJob(id);}
  public void Reconstruct(){Capture(Guid.NewGuid().ToString(),false,"");}
  public void Refine(){
   if(!Active){Status="Select a generated object first";return;}
   if(Active.IsImportedRack){LoadSelectedRack();return;}
   if(jobs.Values.Any(j=>j.objectId==Active.ObjectId)){Status="That item is already being rebuilt";return;}
   if(!Bridge.Connected){Status="Connect the bridge before rebuilding";return;}
   string id=Guid.NewGuid().ToString();try{AddJob(id,Active.ObjectId,true,null,Active.transform.parent.TransformPoint(Active.HomePosition));SyncScene();Status="Searching references to rebuild "+Active.Data.name;Bridge.Send(new JObject{{"type","rebuild"},{"epoch",generationEpoch},{"request_id",id},{"object_id",Active.ObjectId},{"hint",selectedPart==null?"Improve the fidelity of this object using technical references":"Improve component "+selectedPart+" using references; retain other components"}});}catch(Exception e){Status=e.Message;}
  }
  public void ReturnSelected(){Bridge.Send(new JObject{{"type","walkthrough.cancel"}});selectionVersion++;waitForGripRelease=true;if(!Active){Status="Trigger-select a generated item first";return;}EndGrab();pointedTargetLocked=false;Active.ReturnHome();Status="Returned to original anchored position";SyncScene();Store.SaveCurrent();}
  public void Cancel(){if(Rack)Rack.Cancel();generationEpoch++;foreach(var id in jobs.Keys)cancelledJobs.Add(id);if(cancelledJobs.Count>128)cancelledJobs.Clear();Bridge.Send(new JObject{{"type","reconstruction.cancel"},{"epoch",generationEpoch}});ClearJobs();Status="All reconstructions cancelled";}
  public void PullOrReturn(){if(!Active){Status="Reconstruct an object before pulling it out.";return;}if(Active.Extracted)ReturnSelected();else BringToMe();SyncScene();Store.SaveCurrent();}
  public void DeleteSelected(){var result=DeleteActive();Status=result.message;}
  public (bool ok,string message) DeleteActive(){if(!Active)return(false,"No generated object selected");if(jobs.Values.Any(j=>j.objectId==Active.ObjectId))return(false,"Cancel this item’s reconstruction before deleting it");EndGrab();var removed=Active;string name=removed.Data.name;if(!Store.Delete(removed))return(false,Store.Status);if(removed.ObjectId==RackWorld.DefaultId){PlayerPrefs.SetInt("RackDefaultDeleted",1);PlayerPrefs.Save();}selectionVersion++;pointedTargetLocked=false;objects.Remove(removed);Active=objects.LastOrDefault(v=>v);selectedPart=null;if(DetailText)DetailText.text="Deleted generated object: "+name;SyncScene();return(true,"Deleted generated object: "+name);}
  public bool SelectObject(string id){var found=objects.FirstOrDefault(v=>v&&v.ObjectId==id);if(!found)return false;selectionVersion++;pointedTargetLocked=false;Active=found;selectedPart=null;SyncScene();return true;}
  void LockPoint(Vector3 point,Vector3 surfaceNormal){selectionVersion++;pointedTargetLocked=true;lockedTarget=point;lockedNormal=surfaceNormal;selectedPart=null;SyncScene();}
  public bool PointFromCamera(Pose pose,Vector2 point,byte[] image){if(jobs.Count>=MaxJobs)return false;var ray=CameraAccess.ViewportPointToRay(new Vector2(point.x,1-point.y),pose);if(!EnvironmentRaycastManager.IsSupported||!Depth.Raycast(ray,out var hit,6)){Status="No measured surface at that camera point";return false;}target=hit.point;normal=hit.normalConfidence>.3f?hit.normal:(pose.position-target).normalized;hasTarget=true;LockPoint(target,normal);string id=Guid.NewGuid().ToString();Capture(id,false,"",pose,image);return jobs.ContainsKey(id);}
  public byte[] CameraJPEG()=>JPEG();
  public void ExplainNext(){if(!Active){Status="Reconstruct an object before choosing a part.";return;}selectionVersion++;pointedTargetLocked=false;var p=Active.Data.parts[explainIndex++%Active.Data.parts.Count];selectedPart=p.id;Active.Select(p.id);ShowPart(p);SyncScene();Bridge.Send(new JObject{{"type","part.explain"},{"part",p.id}});}
  void ShowPart(PartData p){if(DetailText){var sources=(Active.Data.research?.sources??new List<SourceData>()).Where(s=>(p.sourceIds??Array.Empty<string>()).Contains(s.id));DetailText.text=p.name+" · "+p.evidence+"\n"+(p.function??p.description)+"\n"+p.uncertainty+"\n"+string.Join("\n",sources.Select(s=>s.title+" ["+s.match+"]\n"+s.url));}}
  byte[] JPEG(){var size=CameraAccess.CurrentResolution;var texture=new Texture2D(size.x,size.y,TextureFormat.RGBA32,false);try{texture.LoadRawTextureData(CameraAccess.GetColors());texture.Apply();return texture.EncodeToJPG(78);}finally{Destroy(texture);}}
  void Capture(string id,bool refine,string hint,Pose? inspectedPose=null,byte[] inspectedImage=null,string objectId=null,string detailPart=null){
   if(jobs.Count>=MaxJobs&&!jobs.ContainsKey(id)){FailCapture(id,"Four scans are already running; wait for one to finish");return;}
   if(!Bridge.Connected){FailCapture(id,"Connect the bridge before reconstructing");return;}
   if(!CameraAccess.IsPlaying){FailCapture(id,"Wait for the headset camera");return;}
   try{
    var pose=inspectedPose??CameraAccess.GetCameraPose();var captureTarget=pointedTargetLocked?lockedTarget:target;var captureNormal=pointedTargetLocked?lockedNormal:normal;
    AssemblyVisual original=null;
    if(refine){objectId=objectId??(jobs.TryGetValue(id,out var pending)?pending.objectId:Active?.ObjectId);original=objects.FirstOrDefault(v=>v&&v.ObjectId==objectId);if(!original)throw new Exception("The item to rebuild is unavailable");if(jobs.Values.Any(j=>j.id!=id&&j.objectId==objectId&&(string.IsNullOrEmpty(detailPart)||string.IsNullOrEmpty(j.partId)||original.RelatedParts(detailPart).Contains(j.partId)||original.RelatedParts(j.partId).Contains(detailPart))))throw new Exception("This item is already being rebuilt");captureTarget=original.transform.parent.TransformPoint(original.HomePosition);captureNormal=original.transform.parent.forward;}
    else if(!pointedTargetLocked&&!hasTarget)throw new Exception("Select a mapped surface visible to the camera");
    var viewport=CameraAccess.WorldToViewportPoint(captureTarget,pose);
    if(viewport.x<0||viewport.x>1||viewport.y<0||viewport.y>1||Vector3.Dot(pose.forward,captureTarget-pose.position)<=0)throw new Exception("The pointed object is outside the camera image; look toward it");
    Vector3 LocalRay(float x,float y){var local=Quaternion.Inverse(pose.rotation)*CameraAccess.ViewportPointToRay(new Vector2(x,y),pose).direction;return local/local.z;}
    var capture=new Snapshot{camera=pose,target=captureTarget,normal=captureNormal,ray00=LocalRay(0,0),ray10=LocalRay(1,0),ray01=LocalRay(0,1),ray11=LocalRay(1,1)};
    var data=inspectedImage??JPEG();objectId=refine?original.ObjectId:id;
    var job=AddJob(id,objectId,refine,capture,captureTarget);job.capture=capture;job.partId=detailPart;job.stage="Reading target";Status="Started scan "+job.number+" • "+jobs.Count+" running";
    Bridge.Send(new JObject{{"type","reconstruct"},{"epoch",generationEpoch},{"request_id",id},{"object_id",objectId},{"mode",refine?"refine":"new"},{"part_id",detailPart??""},{"hint",hint},{"target",new JArray(viewport.x,1-viewport.y)},{"distance",Vector3.Distance(captureTarget,pose.position)},{"image","data:image/jpeg;base64,"+Convert.ToBase64String(data)}});
   }catch(Exception e){FailCapture(id,e.Message);}
  }
  void FailCapture(string id,string message){Status=message;RemoveJob(id);Bridge.Send(new JObject{{"type","capture.error"},{"request_id",id},{"message",message}});}
  void SyncScene(){Bridge.Send(new JObject{{"type","scene.update"},{"available_asset_details",Rack?.Available() is JObject catalog?new JArray(catalog):new JArray()},{"selection_version",selectionVersion},{"object_id",Active?.ObjectId??""},{"selected_part",selectedPart??""},{"assembly",Active!=null?JObject.FromObject(Active.Data):JValue.CreateNull()},{"pointing",pointedTargetLocked?new JObject{{"kind","physical_point"},{"position",new JArray(lockedTarget.x,lockedTarget.y,lockedTarget.z)}}:new JObject{{"kind",selectedPart!=null?"generated_part":"generated_object"},{"object_id",Active?.ObjectId??""},{"part_id",selectedPart??""}}}});}
  void OnMessage(JObject e){
   string type=(string)e["type"],messageId=(string)e["request_id"];
   if(type!="reconstruction.cancelled"&&type!="reconstruction.error"&&(type=="capture.request"||type=="rebuild.request"||type.StartsWith("reconstruction."))&&(((int?)e["epoch"]??0)<generationEpoch||(messageId!=null&&cancelledJobs.Contains(messageId))))return;
   Audio.OnMessage(e);switch(type){
   case "connected":generationEpoch=0;cancelledJobs.Clear();SyncScene();break;
   case "reconstruction.cancelled":if((bool?)e["all"]==true&&Rack)Rack.Cancel();generationEpoch=Mathf.Max(generationEpoch,(int?)e["epoch"]??0);if((bool?)e["all"]==true){foreach(var old in jobs.Values.Where(j=>j.epoch<generationEpoch).ToArray()){cancelledJobs.Add(old.id);RemoveJob(old.id);}}if(e["request_ids"] is JArray cancelled){foreach(var id in cancelled){cancelledJobs.Add((string)id);RemoveJob((string)id);}}else if(!string.IsNullOrEmpty((string)e["request_id"]))RemoveJob((string)e["request_id"]);else ClearJobs();Status="Reconstruction cancelled";break;
   case "capture.request":Capture((string)e["request_id"],false,(string)e["hint"]??"");break;
   case "rebuild.request":Capture((string)e["request_id"],true,(string)e["hint"]??"",objectId:(string)e["object_id"],detailPart:(string)e["detail_part"]);break;
   case "view.request":try{if(!CameraAccess.IsPlaying)throw new Exception("Camera not ready");Bridge.Send(new JObject{{"type","view.frame"},{"request_id",e["request_id"]},{"image","data:image/jpeg;base64,"+Convert.ToBase64String(JPEG())}});}catch(Exception error){Bridge.Send(new JObject{{"type","capture.error"},{"request_id",e["request_id"]},{"message",error.Message}});}break;
   case "reconstruction.started":{
    string id=(string)e["request_id"];if(!jobs.ContainsKey(id)&&(string)e["mode"]=="refine"){
     var original=objects.FirstOrDefault(v=>v&&v.ObjectId==(string)e["object_id"]);
     try{if(!original)throw new Exception("Item to refine no longer exists");AddJob(id,original.ObjectId,true,null,original.transform.parent.TransformPoint(original.HomePosition)).partId=(string)e["part_id"];}
     catch(Exception error){Status=error.Message;cancelledJobs.Add(id);Bridge.Send(new JObject{{"type","reconstruction.cancel"},{"request_id",id}});}
    }break;
   }
   case "reconstruction.progress":case "research.warning":if(jobs.TryGetValue((string)e["request_id"],out var progress)){progress.stage=(string)e["stage"]??"Reference warning";Status="Scan "+progress.number+": "+(string)e["message"];}break;
   case "reconstruction.complete":{
    string id=(string)e["request_id"];if(!jobs.TryGetValue(id,out var job))break;
    try{var data=e["assembly"].ToObject<AssemblyData>();data.Validate();
     if(job.refine){var original=objects.FirstOrDefault(v=>v&&v.ObjectId==job.objectId);if(!original)throw new Exception("Original item no longer exists");ReplaceObject(original,data);}
     else Place(data,job.objectId,job.capture,job.selectionVersion==selectionVersion);
     Status="Scan "+job.number+" completed • "+data.name;SyncScene();
    }catch(Exception error){Status="Scan "+job.number+" could not display: "+error.Message;}finally{RemoveJob(id);}break;
   }
   case "reconstruction.error":if(jobs.ContainsKey((string)e["request_id"])){RemoveJob((string)e["request_id"]);Status=(string)e["message"];}break;
   case "part.explanation":var part=e["part"]?.ToObject<PartData>();if(part!=null&&Active&&((string)e["object_id"]==null||(string)e["object_id"]==Active.ObjectId))ShowPart(part);break;
   case "command":if((string)e["action"]=="load_asset_detail"||(string)e["action"]=="unload_asset_detail"){AssetCommand(e);break;}var result=Command(e);SyncScene();Bridge.Send(new JObject{{"type","command.result"},{"call_id",e["call_id"]},{"action",e["action"]},{"ok",result.ok},{"message",result.message}});SyncScene();break;
   case "voice.transcript.delta":voiceCaption+=(string)e["text"];if(DetailText)DetailText.text=voiceCaption;break;
   case "voice.speech_started":voiceCaption="";if(DetailText)DetailText.text="Listening to your question…";break;
   case "voice.transcript":voiceCaption=(string)e["text"];if(DetailText)DetailText.text=voiceCaption;break;
   case "disconnected":ClearJobs();Status="Bridge disconnected; placed objects remain available";break;
  }}
  void Place(AssemblyData data,string id,Snapshot capture,bool select){
   if(capture==null)throw new Exception("Original capture pose missing");var s=capture;var forward=s.normal.normalized;if(Vector3.Dot(forward,s.camera.position-s.target)<0)forward=-forward;
   var up=Mathf.Abs(Vector3.Dot(forward,Vector3.up))>.95f?s.camera.rotation*Vector3.up:Vector3.up;var rotation=Quaternion.LookRotation(forward,up);var plane=new Plane(forward,s.target);
   Vector3 Point(float x,float y){var ray=s.Ray(x,1-y);if(!plane.Raycast(ray,out var distance)||distance>15)throw new Exception("Unreliable surface fit");return ray.GetPoint(distance);}
   var b=data.bounds;float max=data.sizeMeters.Max();Vector3 left=Point(b[0],(b[1]+b[3])/2),right=Point(b[2],(b[1]+b[3])/2),top=Point((b[0]+b[2])/2,b[1]),bottom=Point((b[0]+b[2])/2,b[3]);float scale=Mathf.Clamp((Vector3.Distance(left,right)/(data.sizeMeters[0]/max)+Vector3.Distance(top,bottom)/(data.sizeMeters[1]/max))*.5f,.03f,4);
   var center=Point((b[0]+b[2])/2,(b[1]+b[3])/2)-forward*(data.sizeMeters[2]/max*scale*.5f);
   var anchor=new GameObject("Object source anchor");anchor.transform.SetPositionAndRotation(center,rotation);anchor.AddComponent<OVRSpatialAnchor>();var child=new GameObject(data.name);child.transform.SetParent(anchor.transform,false);child.transform.localScale=Vector3.one*scale;var visual=child.AddComponent<AssemblyVisual>();visual.ObjectId=id;visual.HomeScale=child.transform.localScale;visual.Build(data);objects.Add(visual);if(select&&!grabbed){selectionVersion++;Active=visual;selectedPart=null;pointedTargetLocked=false;}Store.Register(visual);
  }
  void ReplaceObject(AssemblyVisual old,AssemblyData data){var go=new GameObject(data.name);go.transform.SetParent(old.transform.parent,false);go.transform.localPosition=old.transform.localPosition;go.transform.localRotation=old.transform.localRotation;go.transform.localScale=old.transform.localScale;var next=go.AddComponent<AssemblyVisual>();next.ObjectId=old.ObjectId;next.HomePosition=old.HomePosition;next.HomeRotation=old.HomeRotation;next.HomeScale=old.HomeScale;next.Explosion=old.Explosion;next.Extracted=old.Extracted;next.Hologram=old.Hologram;next.ShowInferred=old.ShowInferred;try{next.Build(data);next.CopyInspectionFrom(old);}catch{Destroy(go);throw;}objects.Remove(old);objects.Add(next);if(Active==old){Active=next;if(!data.parts.Any(p=>p.id==selectedPart))selectedPart=null;next.Select(selectedPart);}if(grabbed==old)grabbed=next;old.gameObject.SetActive(false);old.ReleaseImportedAssets();Destroy(old.gameObject);Store.Register(next);}
  public (bool ok,string message) Command(JObject e){if(e["selection_version"]!=null&&(int)e["selection_version"]!=selectionVersion)return(false,"User interaction superseded this command");if(!string.IsNullOrEmpty((string)e["object_id"])&&Active?.ObjectId!=(string)e["object_id"])return(false,"Active object changed");if(!Active)return(false,"No generated object selected");string action=(string)e["action"]??"";selectionVersion++;pointedTargetLocked=false;float amount=(float?)e["amount"]??0;string partQuery=(string)e["part"];if(!string.IsNullOrWhiteSpace(partQuery)&&(action=="rotate"||action=="scale"||action.StartsWith("move_"))){var targetPart=Active.Data.parts.FirstOrDefault(p=>string.Equals(p.id,partQuery,StringComparison.OrdinalIgnoreCase)||p.name.IndexOf(partQuery,StringComparison.OrdinalIgnoreCase)>=0);if(targetPart==null)return(false,"Part not found");selectedPart=targetPart.id;bool applied=Active.ManipulatePart(targetPart.id,action,amount,Rig.centerEyeAnchor);ShowPart(targetPart);return(applied,"Applied "+action+" to "+targetPart.name);}switch(action){case "delete":return DeleteActive();case "explode":Active.SetExplosion(amount>0?amount:1);break;case "assemble":Active.CloseHousing();break;case "reveal_internals":if(!Active.IsImportedRack&&!Active.Extracted)BringToMe();Active.RevealInternals();break;case "close_housing":Active.CloseHousing();break;case "return_part":Active.ReturnPart((string)e["part"]);selectedPart=null;break;case "extract":BringToMe();break;case "return":ReturnSelected();break;case "focus_part":case "select":string q=((string)e["part"]??"").ToLowerInvariant();var p=Active.Data.parts.FirstOrDefault(p=>p.id.ToLowerInvariant()==q||p.name.ToLowerInvariant().Contains(q));if(p==null)return(false,"Part not found");selectedPart=p.id;if(action=="focus_part"){if(!Active.IsImportedRack&&!Active.Extracted)BringToMe();Active.FocusPart(p.id,Rig.centerEyeAnchor);}else Active.Select(p.id);ShowPart(p);break;case "hologram":Active.Hologram=true;Active.Restyle();break;case "solid":Active.Hologram=false;Active.Restyle();break;case "show_inferred":Active.ShowInferred=true;Active.Restyle();break;case "hide_inferred":Active.ShowInferred=false;Active.Restyle();break;case "rotate":if(grabbed){grabRotation=Quaternion.AngleAxis(amount==0?30:amount,Quaternion.Inverse(HandPose().rotation)*Vector3.up)*grabRotation;break;}if(!Active.Extracted)return(false,"Extract first");Active.StopMotion();Active.transform.Rotate(Vector3.up,amount==0?30:amount,Space.World);break;case "scale":if(grabbed){desiredGrabScale*=Mathf.Clamp(amount==0?1.2f:amount,.25f,3);break;}if(!Active.Extracted)return(false,"Extract first");Active.StopMotion();Active.transform.localScale*=Mathf.Clamp(amount==0?1.2f:amount,.25f,3);break;default:if(!action.StartsWith("move_"))return(false,"Unknown command");if(!Active.Extracted)return(false,"Extract first");Vector3 direction=action=="move_left"?-Rig.centerEyeAnchor.right:action=="move_right"?Rig.centerEyeAnchor.right:action=="move_up"?Vector3.up:action=="move_down"?Vector3.down:action=="move_back"?Rig.centerEyeAnchor.forward:-Rig.centerEyeAnchor.forward;var movement=direction*Mathf.Clamp(Mathf.Abs(amount==0?.2f:amount),.05f,1);if(grabbed)desiredGrabOffset+=Quaternion.Inverse(HandPose().rotation)*movement;else{Active.StopMotion();Active.transform.position+=movement;}break;}Store.SaveCurrent();return(true,"Applied "+action);}
  void OnDestroy(){ClearJobs();if(Bridge)Bridge.Message-=OnMessage;}
 }
 public class PanelHandle:MonoBehaviour {}
 public class WorldButton:MonoBehaviour {public Action Action;public void Invoke()=>Action?.Invoke();}
}
