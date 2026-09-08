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
  public BridgeConnection Bridge;public RealtimeAudio Audio;public SavedAssemblies Store;
  public Text StatusText,DetailText,HintText,VoiceButton,PullButton;public Transform Panel;
  bool movingPanel,dragWithTrigger;float panelDistance;Vector3 panelOffset;string voiceCaption="";
  public string Status="Allow camera and spatial-data permissions. Point at an object.";
  public AssemblyVisual Active;readonly List<AssemblyVisual> objects=new();
  Transform marker;LineRenderer pointer;bool lastPinch,busy;string requestId,refiningObject;Snapshot snapshot;Vector3 target,normal;bool hasTarget;float started;string selectedPart;int explainIndex;
  public class Snapshot {
   public Pose camera;public Vector3 target,normal,ray00,ray10,ray01,ray11;
   public Ray Ray(float x,float y){var direction=Vector3.Lerp(Vector3.Lerp(ray00,ray10,x),Vector3.Lerp(ray01,ray11,x),y);return new Ray(camera.position,camera.rotation*direction.normalized);}
  }
  IEnumerator Start(){
   Bridge.Message+=OnMessage;Store.Restored+=v=>{objects.Add(v);Active=v;SyncScene();};Audio.Bridge=Bridge;
   var dot=GameObject.CreatePrimitive(PrimitiveType.Sphere);Destroy(dot.GetComponent<Collider>());marker=dot.transform;marker.localScale=Vector3.one*.016f;dot.GetComponent<Renderer>().material=new Material(Shader.Find("Unlit/Color"));dot.GetComponent<Renderer>().material.color=Color.cyan;
   pointer=new GameObject("Pointing ray").AddComponent<LineRenderer>();pointer.positionCount=2;pointer.startWidth=.002f;pointer.endWidth=.001f;pointer.material=new Material(Shader.Find("Unlit/Color"));pointer.material.color=Color.cyan;
   OVRPermissionsRequester.Request(new[]{OVRPermissionsRequester.Permission.PassthroughCameraAccess,OVRPermissionsRequester.Permission.Scene});
   while(!CameraAccess.IsPlaying){Status="Waiting for passthrough camera permission / camera feed";yield return null;}
   Status="Point with your hand or controller. Pinch or press trigger to reconstruct.";PositionPanel();
  }
  Ray PointingRay(){if(RightHand&&RightHand.IsTracked&&RightHand.IsPointerPoseValid&&RightHand.HandConfidence==OVRHand.TrackingConfidence.High)return new Ray(RightHand.PointerPose.position,RightHand.PointerPose.forward);return new Ray(Rig.rightControllerAnchor.position,Rig.rightControllerAnchor.forward);}
  void Update(){
   if(!Rig||!CameraAccess)return;
   var ray=PointingRay();EnvironmentRaycastHit hit=default;hasTarget=EnvironmentRaycastManager.IsSupported&&Depth.Raycast(ray,out hit,6);
   if(hasTarget){target=hit.point;normal=hit.normalConfidence>.3f?hit.normal:(Rig.centerEyeAnchor.position-target).normalized;if(marker)marker.position=target;}
   if(marker)marker.gameObject.SetActive(hasTarget);if(pointer){pointer.SetPosition(0,ray.origin);pointer.SetPosition(1,hasTarget?target:ray.GetPoint(1));}
   bool pinch=RightHand&&RightHand.IsTracked&&RightHand.IsPointerPoseValid&&RightHand.GetFingerIsPinching(OVRHand.HandFinger.Index);
   bool triggerHeld=pinch||OVRInput.Get(OVRInput.Button.PrimaryIndexTrigger,OVRInput.Controller.RTouch);
   bool grip=OVRInput.Get(OVRInput.Axis1D.PrimaryHandTrigger,OVRInput.Controller.RTouch)>.5f;
   if(OVRInput.GetDown(OVRInput.Button.PrimaryThumbstick,OVRInput.Controller.LTouch))PositionPanel();
   bool onPanel=Physics.Raycast(ray,out var panelHit,6)&&panelHit.collider.transform.IsChildOf(Panel);
   if(!movingPanel&&grip&&onPanel)BeginPanelMove(ray,panelHit.point,false);
   if(movingPanel){if(dragWithTrigger?triggerHeld:grip){panelDistance=Mathf.Clamp(panelDistance+OVRInput.Get(OVRInput.Axis2D.PrimaryThumbstick,OVRInput.Controller.RTouch).y*Time.deltaTime,.45f,2.5f);Panel.position=ray.GetPoint(panelDistance)+panelOffset;Panel.rotation=Quaternion.LookRotation(Panel.position-Rig.centerEyeAnchor.position,Vector3.up);}else movingPanel=false;lastPinch=pinch;UpdateStatus();return;}
   bool pressed=(pinch&&!lastPinch)||OVRInput.GetDown(OVRInput.Button.PrimaryIndexTrigger,OVRInput.Controller.RTouch);lastPinch=pinch;
   if(pressed){if(Physics.Raycast(ray,out var selected,6)){var button=selected.collider.GetComponent<WorldButton>();if(button){button.Invoke();}else if(selected.collider.GetComponent<PanelHandle>()){BeginPanelMove(ray,selected.point,true);}else{var part=selected.collider.GetComponent<PartHandle>();if(part&&!busy){Active=part.Owner;selectedPart=part.Part.id;Active.Select(selectedPart);Active.SetExplosion(Active.Explosion>.05f?0:1);ShowPart(part.Part);SyncScene();}else Reconstruct();}}else Reconstruct();}
   if(OVRInput.GetDown(OVRInput.Button.One,OVRInput.Controller.RTouch)&&Active)Active.SetExplosion(Active.Explosion>.05f?0:1);
   if(OVRInput.GetDown(OVRInput.Button.Two,OVRInput.Controller.RTouch))Audio.Toggle();
   if(OVRInput.GetDown(OVRInput.Button.One,OVRInput.Controller.LTouch))ExplainNext();
   if(OVRInput.GetDown(OVRInput.Button.Two,OVRInput.Controller.LTouch))Refine();
   if(Active&&Active.Extracted&&!busy){var stick=OVRInput.Get(OVRInput.Axis2D.PrimaryThumbstick,OVRInput.Controller.RTouch);Active.transform.position+=Rig.centerEyeAnchor.forward*stick.y*Time.deltaTime*.5f;Active.transform.Rotate(Vector3.up,stick.x*60*Time.deltaTime,Space.World);}
   UpdateStatus();
  }
  void BeginPanelMove(Ray ray,Vector3 point,bool withTrigger){movingPanel=true;dragWithTrigger=withTrigger;panelDistance=Vector3.Distance(ray.origin,point);panelOffset=Panel.position-point;}
  void UpdateStatus(){
   string state=!Bridge.Connected?"OFFLINE":!CameraAccess.IsPlaying?"CAMERA NOT READY":busy?"RECONSTRUCTING":Audio.Speaking?"SPEAKING":Audio.Enabled?"LISTENING":Audio.Starting?"STARTING VOICE":"READY";
   string next=!Bridge.Connected?"Connect Quest to Wi-Fi, then choose Reconnect.":!CameraAccess.IsPlaying?"Allow camera access in the headset.":busy?"Your captured view is processing. You can look around. Cancel stops this request.":Audio.Speaking?"Reply is playing. Speak to interrupt or choose Stop voice.":Audio.Enabled?"Ask a question aloud. Your microphone is on.":Active?"Point at a model part and press trigger to inspect it.":hasTarget?"Point at a real object. Press trigger once to reconstruct it.":"Aim at a nearby real surface until the cyan target appears.";
   if(StatusText){StatusText.text=state+(busy?$"  •  {(int)(Time.realtimeSinceStartup-started)}s":"")+"\n"+(movingPanel?"Moving panel • release to place":next)+"\n"+(busy?Status:Active?"Selected: "+Active.Data.name:Status);StatusText.color=!Bridge.Connected?new Color(1,.65f,.4f):Color.white;}
   if(HintText)HintText.text="Hold grip over panel to move • left stick click: bring panel here\n"+(Audio.Enabled?$"Mic {(Audio.InputLevel>.015f?"hearing sound":"quiet")} • ":"")+Store.Status;
   if(VoiceButton)VoiceButton.text=Audio.Enabled||Audio.Starting?"Stop voice":"Start voice";
   if(PullButton)PullButton.text=Active&&Active.Extracted?"Return object":"Pull object";
  }
  public void PositionPanel(){if(Panel&&Rig){Panel.position=Rig.centerEyeAnchor.position+Rig.centerEyeAnchor.forward*1.25f-Vector3.up*.12f;Panel.rotation=Quaternion.LookRotation(Panel.position-Rig.centerEyeAnchor.position,Vector3.up);}}
  public void Reconstruct(){if(busy){Status="Already reconstructing. Cancel to stop.";return;}Capture(Guid.NewGuid().ToString(),false,"");}
  public void Refine(){if(!Active||busy){Status="Select a generated object first";return;}SyncScene();requestId=Guid.NewGuid().ToString();refiningObject=Active.ObjectId;busy=true;started=Time.realtimeSinceStartup;Status="Searching technical references to rebuild this object";Bridge.Send(new JObject{{"type","rebuild"},{"request_id",requestId},{"hint",selectedPart==null?"Improve the fidelity of this object using technical references":"Improve component "+selectedPart+" using references; retain other components"}});}
  public void Cancel(){Bridge.Send(new JObject{{"type","reconstruction.cancel"}});requestId=null;refiningObject=null;busy=false;Status="Cancelled";}
  public void PullOrReturn(){if(!Active){Status="Reconstruct an object before pulling it out.";return;}if(Active.Extracted)Active.ReturnHome();else Active.PullOut(Rig.centerEyeAnchor);SyncScene();Store.SaveCurrent();}
  public void ExplainNext(){if(!Active){Status="Reconstruct an object before choosing a part.";return;}var p=Active.Data.parts[explainIndex++%Active.Data.parts.Count];selectedPart=p.id;Active.Select(p.id);ShowPart(p);SyncScene();Bridge.Send(new JObject{{"type","part.explain"},{"part",p.id}});}
  void ShowPart(PartData p){if(DetailText){var sources=(Active.Data.research?.sources??new List<SourceData>()).Where(s=>(p.sourceIds??Array.Empty<string>()).Contains(s.id));DetailText.text=p.name+" · "+p.evidence+"\n"+(p.function??p.description)+"\n"+p.uncertainty+"\n"+string.Join("\n",sources.Select(s=>s.title+" ["+s.match+"]\n"+s.url));}}
  byte[] JPEG(){var size=CameraAccess.CurrentResolution;var texture=new Texture2D(size.x,size.y,TextureFormat.RGBA32,false);try{texture.LoadRawTextureData(CameraAccess.GetColors());texture.Apply();return texture.EncodeToJPG(78);}finally{Destroy(texture);}}
  void Capture(string id,bool refine,string hint){
   if(busy&&id!=requestId){Bridge.Send(new JObject{{"type","capture.error"},{"request_id",id},{"message","A reconstruction is already in progress"}});return;}
   if(!Bridge.Connected){Status="Connect the bridge before reconstructing";FailCapture(id,Status);return;}
   if(!CameraAccess.IsPlaying||(!refine&&!hasTarget)){Status="Point at a mapped surface visible to the headset camera";FailCapture(id,Status);return;}
   try{
    // Freeze the sensor pose at the image timestamp. Never project using a later head pose.
    var pose=CameraAccess.GetCameraPose();
    if(refine){if(!Active)throw new Exception("Select the saved object to rebuild");target=Active.transform.parent.TransformPoint(Active.HomePosition);normal=Active.transform.parent.forward;}
    var viewport=CameraAccess.WorldToViewportPoint(target,pose);
    if(viewport.x<0||viewport.x>1||viewport.y<0||viewport.y>1||Vector3.Dot(pose.forward,target-pose.position)<=0){FailCapture(id,"The pointed object is outside the camera image; look toward it");return;}
    Vector3 LocalRay(float x,float y){var local=Quaternion.Inverse(pose.rotation)*CameraAccess.ViewportPointToRay(new Vector2(x,y),pose).direction;return local/local.z;}
    snapshot=new Snapshot{camera=pose,target=target,normal=normal,ray00=LocalRay(0,0),ray10=LocalRay(1,0),ray01=LocalRay(0,1),ray11=LocalRay(1,1)};
    var data=JPEG();requestId=id;refiningObject=refine?Active?.ObjectId:null;busy=true;started=Time.realtimeSinceStartup;Status="Reading the pointed object and searching references";
    Bridge.Send(new JObject{{"type","reconstruct"},{"request_id",id},{"object_id",refine?Active?.ObjectId:id},{"mode",refine?"refine":"new"},{"hint",hint},{"target",new JArray(viewport.x,1-viewport.y)},{"distance",Vector3.Distance(target,pose.position)},{"image","data:image/jpeg;base64,"+Convert.ToBase64String(data)}});
   }catch(Exception e){FailCapture(id,e.Message);}
  }
  void FailCapture(string id,string message){Status=message;busy=false;Bridge.Send(new JObject{{"type","capture.error"},{"request_id",id},{"message",message}});}
  void SyncScene(){Bridge.Send(new JObject{{"type","scene.update"},{"object_id",Active?.ObjectId??""},{"selected_part",selectedPart??""},{"assembly",Active!=null?JObject.FromObject(Active.Data):JValue.CreateNull()}});}
  void OnMessage(JObject e){Audio.OnMessage(e);switch((string)e["type"]){
   case "connected":SyncScene();break;
   case "capture.request":Capture((string)e["request_id"],false,(string)e["hint"]??"");break;
   case "rebuild.request":Capture((string)e["request_id"],true,(string)e["hint"]??"");break;
   case "view.request":try{if(!CameraAccess.IsPlaying)throw new Exception("Camera not ready");Bridge.Send(new JObject{{"type","view.frame"},{"request_id",e["request_id"]},{"image","data:image/jpeg;base64,"+Convert.ToBase64String(JPEG())}});}catch(Exception error){FailCapture((string)e["request_id"],error.Message);}break;
   case "reconstruction.started":if((string)e["mode"]=="refine"){requestId=(string)e["request_id"];refiningObject=Active?.ObjectId;busy=true;started=Time.realtimeSinceStartup;}break;
   case "reconstruction.progress":if((string)e["request_id"]==requestId)Status=(string)e["message"];break;
   case "research.warning":if((string)e["request_id"]==requestId)Status=(string)e["message"];break;
   case "reconstruction.complete":if((string)e["request_id"]!=requestId)return;try{var data=e["assembly"].ToObject<AssemblyData>();data.Validate();if((string)e["mode"]=="refine"){if(!Active||Active.ObjectId!=refiningObject)throw new Exception("Active model changed; discarded stale revision");ReplaceActive(data);}else Place(data,(string)e["object_id"]??requestId);Status="Anchored · point/trigger to select and explode";SyncScene();}catch(Exception ex){Status="Could not display model: "+ex.Message;}finally{busy=false;requestId=null;refiningObject=null;}break;
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
   var anchor=new GameObject("Object source anchor");anchor.transform.SetPositionAndRotation(center,rotation);anchor.AddComponent<OVRSpatialAnchor>();var child=new GameObject(data.name);child.transform.SetParent(anchor.transform,false);child.transform.localScale=Vector3.one*scale;var visual=child.AddComponent<AssemblyVisual>();visual.ObjectId=id;visual.HomeScale=child.transform.localScale;visual.Build(data);objects.Add(visual);Active=visual;selectedPart=null;Store.Register(visual);
  }
  void ReplaceActive(AssemblyData data){var old=Active;var go=new GameObject(data.name);go.transform.SetParent(old.transform.parent,false);go.transform.localPosition=old.transform.localPosition;go.transform.localRotation=old.transform.localRotation;go.transform.localScale=old.transform.localScale;var next=go.AddComponent<AssemblyVisual>();next.ObjectId=old.ObjectId;next.HomePosition=old.HomePosition;next.HomeRotation=old.HomeRotation;next.HomeScale=old.HomeScale;next.Explosion=old.Explosion;next.Extracted=old.Extracted;next.Hologram=old.Hologram;next.ShowInferred=old.ShowInferred;try{next.Build(data);}catch{Destroy(go);throw;}objects.Remove(old);objects.Add(next);Active=next;Destroy(old.gameObject);Store.Register(next);}
  (bool ok,string message) Command(JObject e){if(!Active)return(false,"No generated object selected");string action=(string)e["action"];float amount=(float?)e["amount"]??0;switch(action){case "explode":Active.SetExplosion(amount>0?amount:1);break;case "assemble":Active.SetExplosion(0);break;case "extract":Active.PullOut(Rig.centerEyeAnchor);break;case "return":Active.ReturnHome();break;case "select":string q=((string)e["part"]??"").ToLowerInvariant();var p=Active.Data.parts.FirstOrDefault(p=>p.id.ToLowerInvariant()==q||p.name.ToLowerInvariant().Contains(q));if(p==null)return(false,"Part not found");selectedPart=p.id;Active.Select(p.id);ShowPart(p);break;case "hologram":Active.Hologram=true;Active.Restyle();break;case "solid":Active.Hologram=false;Active.Restyle();break;case "show_inferred":Active.ShowInferred=true;Active.Restyle();break;case "hide_inferred":Active.ShowInferred=false;Active.Restyle();break;case "rotate":if(!Active.Extracted)return(false,"Extract first");Active.transform.Rotate(Vector3.up,amount==0?30:amount,Space.World);break;case "scale":if(!Active.Extracted)return(false,"Extract first");Active.transform.localScale*=Mathf.Clamp(amount==0?1.2f:amount,.25f,3);break;default:if(!action.StartsWith("move_"))return(false,"Unknown command");if(!Active.Extracted)return(false,"Extract first");Vector3 direction=action=="move_left"?-Rig.centerEyeAnchor.right:action=="move_right"?Rig.centerEyeAnchor.right:action=="move_up"?Vector3.up:action=="move_down"?Vector3.down:action=="move_back"?Rig.centerEyeAnchor.forward:-Rig.centerEyeAnchor.forward;Active.transform.position+=direction*Mathf.Clamp(Mathf.Abs(amount==0?.2f:amount),.05f,1);break;}Store.SaveCurrent();return(true,"Applied "+action);}
  void OnDestroy(){if(Bridge)Bridge.Message-=OnMessage;}
 }
 public class PanelHandle:MonoBehaviour {}
 public class WorldButton:MonoBehaviour {public Action Action;public void Invoke()=>Action?.Invoke();}
}
