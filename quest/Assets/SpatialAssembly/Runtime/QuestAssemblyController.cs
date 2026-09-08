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
  public Text StatusText,DetailText,HintText,VoiceButton,PullButton;public Transform Panel;
  AssemblyVisual grabbed;Vector3 grabOffset,desiredGrabOffset,grabVelocity,desiredGrabScale;Quaternion grabRotation;bool grabByPinch,lastGrip;Transform scanMarker;TextMesh scanLabel;
  bool waitForGripRelease;bool panelFollows=true;string voiceCaption="";
  public bool Busy=>busy;public string SelectedPart=>selectedPart;public IEnumerable<AssemblyVisual> Objects=>objects.Where(v=>v);
  public string Status="Allow camera and spatial-data permissions. Point at an object.";
  public AssemblyVisual Active;readonly List<AssemblyVisual> objects=new();
  bool pointedTargetLocked;Vector3 lockedTarget,lockedNormal;
  Transform marker;LineRenderer pointer;bool lastPinch,busy;string requestId,refiningObject;Snapshot snapshot;Vector3 target,normal;bool hasTarget;float started;string selectedPart;int explainIndex;
  public class Snapshot {
   public Pose camera;public Vector3 target,normal,ray00,ray10,ray01,ray11;
   public Ray Ray(float x,float y){var direction=Vector3.Lerp(Vector3.Lerp(ray00,ray10,x),Vector3.Lerp(ray01,ray11,x),y);return new Ray(camera.position,camera.rotation*direction.normalized);}
  }
  IEnumerator Start(){
   Bridge.Message+=OnMessage;Store.Restored+=v=>{objects.Add(v);if(!grabbed){Active=v;selectedPart=null;pointedTargetLocked=false;}SyncScene();};Audio.Bridge=Bridge;
   var dot=GameObject.CreatePrimitive(PrimitiveType.Sphere);Destroy(dot.GetComponent<Collider>());marker=dot.transform;marker.localScale=Vector3.one*.016f;dot.GetComponent<Renderer>().material=new Material(Shader.Find("Unlit/Color"));dot.GetComponent<Renderer>().material.color=Color.cyan;
   pointer=new GameObject("Pointing ray").AddComponent<LineRenderer>();pointer.positionCount=2;pointer.startWidth=.002f;pointer.endWidth=.001f;pointer.material=new Material(Shader.Find("Unlit/Color"));pointer.material.color=Color.cyan;
   scanMarker=GameObject.CreatePrimitive(PrimitiveType.Sphere).transform;scanMarker.name="Captured scan target";Destroy(scanMarker.GetComponent<Collider>());scanMarker.localScale=Vector3.one*.035f;scanMarker.GetComponent<Renderer>().material=new Material(Shader.Find("Unlit/Color"));scanMarker.GetComponent<Renderer>().material.color=new Color(1,.65f,.1f);
   scanLabel=new GameObject("Scan progress").AddComponent<TextMesh>();scanLabel.font=Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");scanLabel.GetComponent<Renderer>().sharedMaterial=scanLabel.font.material;scanLabel.fontSize=48;scanLabel.characterSize=.018f;scanLabel.anchor=TextAnchor.MiddleCenter;scanLabel.color=new Color(1,.8f,.3f);
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
   if(scanMarker){scanMarker.gameObject.SetActive(busy&&snapshot!=null);scanLabel.gameObject.SetActive(busy&&snapshot!=null);if(busy&&snapshot!=null){scanMarker.position=snapshot.target;scanLabel.transform.position=snapshot.target+Vector3.up*.08f;scanLabel.transform.rotation=Quaternion.LookRotation(scanLabel.transform.position-Rig.centerEyeAnchor.position,Vector3.up);scanLabel.text="Scanning • "+(int)(Time.realtimeSinceStartup-started)+"s";}}
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
   if(OVRInput.GetDown(OVRInput.Button.PrimaryThumbstick,OVRInput.Controller.LTouch)){if(leftGrip)Store.Restore();else {Panel.gameObject.SetActive(!Panel.gameObject.activeSelf);if(Panel.gameObject.activeSelf)PositionPanel();}}
   if(OVRInput.GetDown(OVRInput.Button.One,OVRInput.Controller.RTouch)&&Active){if(leftGrip)BringToMe();else Active.SetExplosion(Active.Explosion>.05f?0:1);}
   if(OVRInput.GetDown(OVRInput.Button.Two,OVRInput.Controller.RTouch)){if(leftGrip&&TestControl)TestControl.ToggleTest();else Audio.Toggle();}
   if(OVRInput.GetDown(OVRInput.Button.One,OVRInput.Controller.LTouch)){if(leftGrip)DeleteSelected();else ExplainNext();}
   if(OVRInput.GetDown(OVRInput.Button.Two,OVRInput.Controller.LTouch)){if(leftGrip||busy)Cancel();else Refine();}
   if(OVRInput.GetDown(OVRInput.Button.PrimaryThumbstick,OVRInput.Controller.RTouch)){if(pointedTargetLocked){if(!busy)Reconstruct();}else ReturnSelected();}
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
   if(!waitForGripRelease&&(!busy||refiningObject==null)){
    var item=part?part.Owner:(!pointedTargetLocked?Active:null);
    if(item&&((part&&pinch&&pressed)||gripDown)){
     if(part)selectedPart=part.Part.id;grabByPinch=pinch;BeginGrab(item,HandPose());
     Active.Select(selectedPart);if(part)ShowPart(part.Part);UpdateStatus();return;
    }
   }
   if(pressed){if(part){pointedTargetLocked=false;Active=part.Owner;selectedPart=part.Part.id;Active.Select(selectedPart);ShowPart(part.Part);SyncScene();}else if(hasTarget){LockPoint(target,normal);Status="Target selected • right stick click to scan, or explicitly ask to reconstruct";}}
   if(Active&&Active.Extracted&&!busy){var stick=OVRInput.Get(OVRInput.Axis2D.PrimaryThumbstick,OVRInput.Controller.RTouch);if(!pointedTargetLocked){float x=StickValue(stick.x),y=StickValue(stick.y);if(x!=0||y!=0)Active.StopMotion();if(leftGrip)Active.transform.Rotate(Rig.centerEyeAnchor.right,-y*90*Time.deltaTime,Space.World);else Active.transform.position+=Rig.centerEyeAnchor.forward*y*Time.deltaTime*1.2f;Active.transform.Rotate(Vector3.up,x*110*Time.deltaTime,Space.World);}}
   UpdateStatus();
  }
  static float StickValue(float value)=>Mathf.Abs(value)<.18f?0:Mathf.Sign(value)*(Mathf.Abs(value)-.18f)/.82f;
  public void BeginGrab(AssemblyVisual item,Pose hand){
   pointedTargetLocked=false;grabbed=item;Active=item;item.StopMotion();item.Extracted=true;grabVelocity=Vector3.zero;
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
  public void BringToMe(){if(!Active){Status="Trigger-select a generated item first";return;}if(grabbed){desiredGrabOffset=new Vector3(0,0,.6f);desiredGrabScale=grabbed.InspectionScale(.65f);}else Active.PullOut(Rig.centerEyeAnchor);pointedTargetLocked=false;Status="Bringing selected item within reach";SyncScene();Store.SaveCurrent();}
  public void EndGrab(){grabbed=null;grabVelocity=Vector3.zero;SyncScene();Store.SaveCurrent();}
  public void PlaceActive(Vector3 point,Vector3 surfaceNormal){if(grabbed)Active=grabbed;if(!Active)return;pointedTargetLocked=false;EndGrab();Active.Extracted=true;var size=AssemblyData.V(Active.Data.sizeMeters)/Active.Data.sizeMeters.Max();var scale=Active.transform.lossyScale;float support=(Mathf.Abs(Vector3.Dot(surfaceNormal,Active.transform.right))*size.x*scale.x+Mathf.Abs(Vector3.Dot(surfaceNormal,Active.transform.up))*size.y*scale.y+Mathf.Abs(Vector3.Dot(surfaceNormal,Active.transform.forward))*size.z*scale.z)*.5f;Active.transform.position=point+surfaceNormal*Mathf.Max(.01f,support);Status="Placed • grip to move again, or say return object";SyncScene();Store.SaveCurrent();}
  void UpdateStatus(){
   string state=!Bridge.Connected?"OFFLINE":!CameraAccess.IsPlaying?"CAMERA NOT READY":grabbed?"HOLDING OBJECT":busy?"RECONSTRUCTING":pointedTargetLocked?"TARGET SELECTED":!string.IsNullOrEmpty(Audio.Error)?"VOICE ERROR":Audio.Speaking?"SPEAKING":Audio.Enabled?"LISTENING":Audio.Starting?"STARTING VOICE":"READY";
   string next=!Bridge.Connected?"Reconnecting automatically. Check Quest and Mac Wi-Fi.":!CameraAccess.IsPlaying?"Allow camera access in the headset.":grabbed?"Twist your wrist to rotate. Stick turns / moves closer. Release grip to drop.":busy?"Captured target is amber. Press Y to cancel immediately.":pointedTargetLocked?"Right stick click confirms reconstruction. Trigger alone does not scan.":!string.IsNullOrEmpty(Audio.Error)?Audio.Error+" Press B to retry voice.":Audio.Speaking?"Reply is playing. Speak to interrupt or press B to stop voice.":Audio.Enabled?"Ask a question aloud. Your microphone is on.":Active?Active.Extracted?"Hold grip to bring the selected item to your hand. Stick turns it; right-stick click returns it.":"Trigger selects a part. Hold grip to bring it to you. A explodes.":hasTarget?"Trigger selects a target. Right stick click confirms the scan.":"Aim at a nearby real surface until the cyan target appears.";
   if(StatusText){StatusText.text=state+(busy?$"  •  {(int)(Time.realtimeSinceStartup-started)}s":"")+"\n"+next+"\n"+(busy?Status:pointedTargetLocked?"Target selected; awaiting your reconstruction request":Active?"Selected: "+Active.Data.name:Status);StatusText.color=!Bridge.Connected?new Color(1,.65f,.4f):Color.white;}
   if(HintText)HintText.text="Trigger selects • Grip brings / holds • Release drops\nTwist wrist to rotate • Stick: turn / near–far\nLeft grip + stick up/down: tilt • Left grip + A: bring here\nA: explode • B: voice • X: explain • Y: cancel / improve\nRight stick click: confirm scan / return selected item\nLeft grip + X: delete • Holding + trigger: place\nLeft stick click: hide guide • + left grip: restore";
   if(VoiceButton)VoiceButton.text=Audio.Enabled||Audio.Starting?"Stop voice":"Start voice";
   if(PullButton)PullButton.text=Active&&Active.Extracted?"Return object":"Pull object";
  }
  public void PositionPanel(){panelFollows=true;PlacePanelAtEyeHeight(true);}
  void PlacePanelAtEyeHeight(bool immediate){if(Panel&&Rig){var forward=Vector3.ProjectOnPlane(Rig.centerEyeAnchor.forward,Vector3.up);if(forward.sqrMagnitude<.01f)forward=Vector3.ProjectOnPlane(Rig.transform.forward,Vector3.up);forward.Normalize();var right=Vector3.Cross(Vector3.up,forward);var desired=Rig.centerEyeAnchor.position+forward*1.15f-right*.48f-Vector3.up*.13f;var rotation=Quaternion.LookRotation(desired-Rig.centerEyeAnchor.position,Vector3.up);if(immediate||Vector3.Distance(Panel.position,desired)>.12f||Quaternion.Angle(Panel.rotation,rotation)>12){float blend=immediate?1:1-Mathf.Exp(-7*Time.deltaTime);Panel.position=Vector3.Lerp(Panel.position,desired,blend);Panel.rotation=Quaternion.Slerp(Panel.rotation,rotation,blend);}}}
  public void Reconstruct(){if(busy){Status="Already reconstructing. Cancel to stop.";return;}Capture(Guid.NewGuid().ToString(),false,"");}
  public void Refine(){if(!Active||busy){Status="Select a generated object first";return;}SyncScene();requestId=Guid.NewGuid().ToString();refiningObject=Active.ObjectId;busy=true;started=Time.realtimeSinceStartup;Status="Searching technical references to rebuild this object";Bridge.Send(new JObject{{"type","rebuild"},{"request_id",requestId},{"hint",selectedPart==null?"Improve the fidelity of this object using technical references":"Improve component "+selectedPart+" using references; retain other components"}});}
  public void ReturnSelected(){waitForGripRelease=true;if(!Active){Status="Trigger-select a generated item first";return;}EndGrab();pointedTargetLocked=false;Active.ReturnHome();Status="Returned to original anchored position";SyncScene();Store.SaveCurrent();}
  public void Cancel(){Bridge.Send(new JObject{{"type","reconstruction.cancel"}});requestId=null;refiningObject=null;busy=false;Status="Cancelled";}
  public void PullOrReturn(){if(!Active){Status="Reconstruct an object before pulling it out.";return;}if(Active.Extracted)ReturnSelected();else BringToMe();SyncScene();Store.SaveCurrent();}
  public void DeleteSelected(){var result=DeleteActive();Status=result.message;}
  public (bool ok,string message) DeleteActive(){if(!Active)return(false,"No generated object selected");if(busy)return(false,"Cancel the current reconstruction before deleting");EndGrab();var removed=Active;string name=removed.Data.name;if(!Store.Delete(removed))return(false,Store.Status);pointedTargetLocked=false;objects.Remove(removed);Active=objects.LastOrDefault(v=>v);selectedPart=null;if(DetailText)DetailText.text="Deleted generated object: "+name;SyncScene();return(true,"Deleted generated object: "+name);}
  public bool SelectObject(string id){var found=objects.FirstOrDefault(v=>v&&v.ObjectId==id);if(!found)return false;pointedTargetLocked=false;Active=found;selectedPart=null;SyncScene();return true;}
  void LockPoint(Vector3 point,Vector3 surfaceNormal){pointedTargetLocked=true;lockedTarget=point;lockedNormal=surfaceNormal;selectedPart=null;SyncScene();}
  public bool PointFromCamera(Pose pose,Vector2 point,byte[] image){if(busy)return false;var ray=CameraAccess.ViewportPointToRay(new Vector2(point.x,1-point.y),pose);if(!EnvironmentRaycastManager.IsSupported||!Depth.Raycast(ray,out var hit,6)){Status="No measured surface at that camera point";return false;}target=hit.point;normal=hit.normalConfidence>.3f?hit.normal:(pose.position-target).normalized;hasTarget=true;LockPoint(target,normal);Capture(Guid.NewGuid().ToString(),false,"",pose,image);return busy;}
  public byte[] CameraJPEG()=>JPEG();
  public void ExplainNext(){if(!Active){Status="Reconstruct an object before choosing a part.";return;}pointedTargetLocked=false;var p=Active.Data.parts[explainIndex++%Active.Data.parts.Count];selectedPart=p.id;Active.Select(p.id);ShowPart(p);SyncScene();Bridge.Send(new JObject{{"type","part.explain"},{"part",p.id}});}
  void ShowPart(PartData p){if(DetailText){var sources=(Active.Data.research?.sources??new List<SourceData>()).Where(s=>(p.sourceIds??Array.Empty<string>()).Contains(s.id));DetailText.text=p.name+" · "+p.evidence+"\n"+(p.function??p.description)+"\n"+p.uncertainty+"\n"+string.Join("\n",sources.Select(s=>s.title+" ["+s.match+"]\n"+s.url));}}
  byte[] JPEG(){var size=CameraAccess.CurrentResolution;var texture=new Texture2D(size.x,size.y,TextureFormat.RGBA32,false);try{texture.LoadRawTextureData(CameraAccess.GetColors());texture.Apply();return texture.EncodeToJPG(78);}finally{Destroy(texture);}}
  void Capture(string id,bool refine,string hint,Pose? inspectedPose=null,byte[] inspectedImage=null){
   if(!refine&&pointedTargetLocked){target=lockedTarget;normal=lockedNormal;hasTarget=true;}
   if(busy&&id!=requestId){Bridge.Send(new JObject{{"type","capture.error"},{"request_id",id},{"message","A reconstruction is already in progress"}});return;}
   if(!Bridge.Connected){Status="Connect the bridge before reconstructing";FailCapture(id,Status);return;}
   if(!CameraAccess.IsPlaying||(!refine&&!hasTarget)){Status="Point at a mapped surface visible to the headset camera";FailCapture(id,Status);return;}
   try{
    // Freeze the sensor pose at the image timestamp. Never project using a later head pose.
    var pose=inspectedPose??CameraAccess.GetCameraPose();
    if(refine){if(!Active)throw new Exception("Select the saved object to rebuild");target=Active.transform.parent.TransformPoint(Active.HomePosition);normal=Active.transform.parent.forward;}
    var viewport=CameraAccess.WorldToViewportPoint(target,pose);
    if(viewport.x<0||viewport.x>1||viewport.y<0||viewport.y>1||Vector3.Dot(pose.forward,target-pose.position)<=0){FailCapture(id,"The pointed object is outside the camera image; look toward it");return;}
    Vector3 LocalRay(float x,float y){var local=Quaternion.Inverse(pose.rotation)*CameraAccess.ViewportPointToRay(new Vector2(x,y),pose).direction;return local/local.z;}
    snapshot=new Snapshot{camera=pose,target=target,normal=normal,ray00=LocalRay(0,0),ray10=LocalRay(1,0),ray01=LocalRay(0,1),ray11=LocalRay(1,1)};
    var data=inspectedImage??JPEG();requestId=id;refiningObject=refine?Active?.ObjectId:null;busy=true;started=Time.realtimeSinceStartup;Status="Reading the pointed object and searching references";
    Bridge.Send(new JObject{{"type","reconstruct"},{"request_id",id},{"object_id",refine?Active?.ObjectId:id},{"mode",refine?"refine":"new"},{"hint",hint},{"target",new JArray(viewport.x,1-viewport.y)},{"distance",Vector3.Distance(target,pose.position)},{"image","data:image/jpeg;base64,"+Convert.ToBase64String(data)}});
   }catch(Exception e){FailCapture(id,e.Message);}
  }
  void FailCapture(string id,string message){Status=message;busy=false;Bridge.Send(new JObject{{"type","capture.error"},{"request_id",id},{"message",message}});}
  void SyncScene(){Bridge.Send(new JObject{{"type","scene.update"},{"object_id",Active?.ObjectId??""},{"selected_part",selectedPart??""},{"assembly",Active!=null?JObject.FromObject(Active.Data):JValue.CreateNull()},{"pointing",pointedTargetLocked?new JObject{{"kind","physical_point"},{"position",new JArray(lockedTarget.x,lockedTarget.y,lockedTarget.z)}}:new JObject{{"kind",selectedPart!=null?"generated_part":"generated_object"},{"object_id",Active?.ObjectId??""},{"part_id",selectedPart??""}}}});}
  void OnMessage(JObject e){Audio.OnMessage(e);switch((string)e["type"]){
   case "connected":SyncScene();break;
   case "reconstruction.cancelled":requestId=null;refiningObject=null;busy=false;Status="Cancelled";break;
   case "capture.request":Capture((string)e["request_id"],false,(string)e["hint"]??"");break;
   case "rebuild.request":Capture((string)e["request_id"],true,(string)e["hint"]??"");break;
   case "view.request":try{if(!CameraAccess.IsPlaying)throw new Exception("Camera not ready");Bridge.Send(new JObject{{"type","view.frame"},{"request_id",e["request_id"]},{"image","data:image/jpeg;base64,"+Convert.ToBase64String(JPEG())}});}catch(Exception error){Bridge.Send(new JObject{{"type","capture.error"},{"request_id",e["request_id"]},{"message",error.Message}});}break;
   case "reconstruction.started":if((string)e["mode"]=="refine"){requestId=(string)e["request_id"];refiningObject=Active?.ObjectId;busy=true;started=Time.realtimeSinceStartup;}break;
   case "reconstruction.progress":if((string)e["request_id"]==requestId)Status=(string)e["message"];break;
   case "research.warning":if((string)e["request_id"]==requestId)Status=(string)e["message"];break;
   case "reconstruction.complete":if((string)e["request_id"]!=requestId)return;try{var data=e["assembly"].ToObject<AssemblyData>();data.Validate();if((string)e["mode"]=="refine"){if(!Active||Active.ObjectId!=refiningObject)throw new Exception("Active model changed; discarded stale revision");ReplaceActive(data);}else Place(data,(string)e["object_id"]??requestId);Status="Anchored · trigger selects a part; A explodes";SyncScene();}catch(Exception ex){Status="Could not display model: "+ex.Message;}finally{busy=false;requestId=null;refiningObject=null;}break;
   case "reconstruction.error":if((string)e["request_id"]==requestId){busy=false;requestId=null;Status=(string)e["message"];}break;
   case "part.explanation":var part=e["part"]?.ToObject<PartData>();if(part!=null&&Active)ShowPart(part);break;
   case "command":var result=Command(e);Bridge.Send(new JObject{{"type","command.result"},{"call_id",e["call_id"]},{"action",e["action"]},{"ok",result.ok},{"message",result.message}});SyncScene();break;
   case "voice.transcript.delta":voiceCaption+=(string)e["text"];if(DetailText)DetailText.text=voiceCaption;break;
   case "voice.speech_started":voiceCaption="";if(DetailText)DetailText.text="Listening to your question…";break;
   case "voice.transcript":voiceCaption=(string)e["text"];if(DetailText)DetailText.text=voiceCaption;break;
   case "disconnected":busy=false;requestId=null;Status="Bridge disconnected; placed objects remain available";break;
  }}
  void Place(AssemblyData data,string id){
   if(snapshot==null)throw new Exception("Original capture pose missing");var s=snapshot;var forward=s.normal.normalized;if(Vector3.Dot(forward,s.camera.position-s.target)<0)forward=-forward;
   var up=Mathf.Abs(Vector3.Dot(forward,Vector3.up))>.95f?s.camera.rotation*Vector3.up:Vector3.up;var rotation=Quaternion.LookRotation(forward,up);var plane=new Plane(forward,s.target);
   Vector3 Point(float x,float y){var ray=s.Ray(x,1-y);if(!plane.Raycast(ray,out var distance)||distance>15)throw new Exception("Unreliable surface fit");return ray.GetPoint(distance);}
   var b=data.bounds;float max=data.sizeMeters.Max();Vector3 left=Point(b[0],(b[1]+b[3])/2),right=Point(b[2],(b[1]+b[3])/2),top=Point((b[0]+b[2])/2,b[1]),bottom=Point((b[0]+b[2])/2,b[3]);float scale=Mathf.Clamp((Vector3.Distance(left,right)/(data.sizeMeters[0]/max)+Vector3.Distance(top,bottom)/(data.sizeMeters[1]/max))*.5f,.03f,4);
   var center=Point((b[0]+b[2])/2,(b[1]+b[3])/2)-forward*(data.sizeMeters[2]/max*scale*.5f);
   var anchor=new GameObject("Object source anchor");anchor.transform.SetPositionAndRotation(center,rotation);anchor.AddComponent<OVRSpatialAnchor>();var child=new GameObject(data.name);child.transform.SetParent(anchor.transform,false);child.transform.localScale=Vector3.one*scale;var visual=child.AddComponent<AssemblyVisual>();visual.ObjectId=id;visual.HomeScale=child.transform.localScale;visual.Build(data);objects.Add(visual);if(!grabbed){Active=visual;selectedPart=null;pointedTargetLocked=false;}Store.Register(visual);
  }
  void ReplaceActive(AssemblyData data){var old=Active;var go=new GameObject(data.name);go.transform.SetParent(old.transform.parent,false);go.transform.localPosition=old.transform.localPosition;go.transform.localRotation=old.transform.localRotation;go.transform.localScale=old.transform.localScale;var next=go.AddComponent<AssemblyVisual>();next.ObjectId=old.ObjectId;next.HomePosition=old.HomePosition;next.HomeRotation=old.HomeRotation;next.HomeScale=old.HomeScale;next.Explosion=old.Explosion;next.Extracted=old.Extracted;next.Hologram=old.Hologram;next.ShowInferred=old.ShowInferred;try{next.Build(data);}catch{Destroy(go);throw;}objects.Remove(old);objects.Add(next);Active=next;if(grabbed==old)grabbed=next;selectedPart=null;pointedTargetLocked=false;Destroy(old.gameObject);Store.Register(next);}
  public (bool ok,string message) Command(JObject e){if(!Active)return(false,"No generated object selected");string action=(string)e["action"]??"";pointedTargetLocked=false;float amount=(float?)e["amount"]??0;switch(action){case "delete":return DeleteActive();case "explode":Active.SetExplosion(amount>0?amount:1);break;case "assemble":Active.SetExplosion(0);break;case "extract":BringToMe();break;case "return":ReturnSelected();break;case "select":string q=((string)e["part"]??"").ToLowerInvariant();var p=Active.Data.parts.FirstOrDefault(p=>p.id.ToLowerInvariant()==q||p.name.ToLowerInvariant().Contains(q));if(p==null)return(false,"Part not found");selectedPart=p.id;Active.Select(p.id);ShowPart(p);break;case "hologram":Active.Hologram=true;Active.Restyle();break;case "solid":Active.Hologram=false;Active.Restyle();break;case "show_inferred":Active.ShowInferred=true;Active.Restyle();break;case "hide_inferred":Active.ShowInferred=false;Active.Restyle();break;case "rotate":if(grabbed){grabRotation=Quaternion.AngleAxis(amount==0?30:amount,Quaternion.Inverse(HandPose().rotation)*Vector3.up)*grabRotation;break;}if(!Active.Extracted)return(false,"Extract first");Active.StopMotion();Active.transform.Rotate(Vector3.up,amount==0?30:amount,Space.World);break;case "scale":if(grabbed){desiredGrabScale*=Mathf.Clamp(amount==0?1.2f:amount,.25f,3);break;}if(!Active.Extracted)return(false,"Extract first");Active.StopMotion();Active.transform.localScale*=Mathf.Clamp(amount==0?1.2f:amount,.25f,3);break;default:if(!action.StartsWith("move_"))return(false,"Unknown command");if(!Active.Extracted)return(false,"Extract first");Vector3 direction=action=="move_left"?-Rig.centerEyeAnchor.right:action=="move_right"?Rig.centerEyeAnchor.right:action=="move_up"?Vector3.up:action=="move_down"?Vector3.down:action=="move_back"?Rig.centerEyeAnchor.forward:-Rig.centerEyeAnchor.forward;var movement=direction*Mathf.Clamp(Mathf.Abs(amount==0?.2f:amount),.05f,1);if(grabbed)desiredGrabOffset+=Quaternion.Inverse(HandPose().rotation)*movement;else{Active.StopMotion();Active.transform.position+=movement;}break;}Store.SaveCurrent();return(true,"Applied "+action);}
  void OnDestroy(){if(Bridge)Bridge.Message-=OnMessage;}
 }
 public class PanelHandle:MonoBehaviour {}
 public class WorldButton:MonoBehaviour {public Action Action;public void Invoke()=>Action?.Invoke();}
}
