using System;
using System.Linq;
using Newtonsoft.Json.Linq;
using UnityEngine;
namespace SpatialAssembly {
 public class QuestTestControl:MonoBehaviour {
  public BridgeConnection Link;public QuestAssemblyController Controller;
  Pose snapshotPose;byte[] snapshotImage;string snapshotId;float snapshotAt,lastFresh=-100;DateTime lastTimestamp;bool paused;
  void Start(){Link.Message+=Handle;}
  void Update(){if(Controller.CameraAccess.IsPlaying&&Controller.CameraAccess.Timestamp!=lastTimestamp){lastTimestamp=Controller.CameraAccess.Timestamp;lastFresh=Time.realtimeSinceStartup;}}
  public void ToggleTest(){Link.SetEnabled(!Link.UserEnabled);}
  static JArray V(Vector3 value)=>new JArray(value.x,value.y,value.z);
  JObject State(){var c=Controller;return new JObject{
   {"platform","quest"},{"phase",c.Status},{"busy",c.Busy},{"bridgeConnected",c.Bridge.Connected},{"cameraPlaying",c.CameraAccess.IsPlaying},{"frameAge",Time.realtimeSinceStartup-lastFresh},{"voiceOn",c.Audio.Enabled},{"speaking",c.Audio.Speaking},{"voiceStatus",c.Audio.Status},
   {"object",c.Active?c.Active.Data.name:""},{"objectID",c.Active?c.Active.ObjectId:""},{"selectedPart",c.SelectedPart??""},{"voiceError",c.Audio.Error},{"savedObjectIDs",new JArray(c.Store.SavedObjectIds)},
   {"objects",new JArray(c.Objects.Select(v=>new JObject{{"id",v.ObjectId},{"name",v.Data.name},{"position",V(v.transform.position)},{"extracted",v.Extracted},{"explosion",v.Explosion},{"parts",new JArray(v.Data.parts.Select(p=>new JObject{{"id",p.id},{"name",p.name}}))}}))},
   {"headPosition",V(c.Rig.centerEyeAnchor.position)},{"panelPosition",V(c.Panel.position)},{"transcript",c.DetailText?c.DetailText.text:""}};}
  void Handle(JObject e){if((string)e["type"]!="test.command")return;string id=(string)e["id"];
   void Reply(bool ok,string message,string image=null){var result=new JObject{{"type","test.result"},{"id",id},{"ok",ok},{"message",message},{"state",State()}};if(image!=null){result["image"]=image;result["frameId"]=snapshotId;}Link.Send(result);}
   if(paused||!Link.UserEnabled){Reply(false,"Quest test connection is paused");return;}
   try{switch((string)e["action"]){
    case "state":Reply(true,"Actual Quest state");break;
    case "snapshot":if(!Controller.CameraAccess.IsPlaying||Time.realtimeSinceStartup-lastFresh>1){Reply(false,"No fresh headset camera frame");break;}snapshotPose=Controller.CameraAccess.GetCameraPose();snapshotAt=Time.realtimeSinceStartup;snapshotId=Guid.NewGuid().ToString();snapshotImage=Controller.CameraJPEG();Reply(true,"Actual left passthrough camera image; generated geometry and panel are visible separately in browser casting",Convert.ToBase64String(snapshotImage));break;
    case "tap":if((string)e["frameId"]!=snapshotId||snapshotId==null||Time.realtimeSinceStartup-snapshotAt>10){Reply(false,"Inspect a fresh snapshot and pass its frameId");break;}float x=(float)e["x"],y=(float)e["y"];if(x<0||x>1||y<0||y>1){Reply(false,"Coordinates must be normalized");break;}bool started=Controller.PointFromCamera(snapshotPose,new Vector2(x,y),snapshotImage);Reply(started,started?"Reconstruction started using the inspected image and pose, with current depth; wait for completion":Controller.Status);break;
    case "cancel":Controller.Cancel();Reply(true,"Cancelled");break;
    case "manipulate":string objectId=(string)e["objectId"];if(!string.IsNullOrEmpty(objectId)&&(!Controller.Active||Controller.Active.ObjectId!=objectId)){Reply(false,"Active object changed; inspect state again");break;}var result=Controller.Command(new JObject{{"action",(string)e["operation"]},{"amount",(float?)e["amount"]??0},{"part",(string)e["part"]??""}});Reply(result.ok,result.message);break;
    case "reconstruct":Controller.Reconstruct();Reply(Controller.Busy,Controller.Status);break;
    case "refine":Controller.Refine();Reply(Controller.Busy,Controller.Status);break;
    case "explain":Controller.ExplainNext();Reply(Controller.Active!=null,"Selected next part for explanation");break;
    case "voice.start":if(!Controller.Audio.Enabled&&!Controller.Audio.Starting)Controller.Audio.Toggle();Reply(true,"Voice requested; check state for actual readiness");break;
    case "voice.stop":Controller.Audio.Stop();Reply(true,"Voice stopped");break;
    case "ask":if(!Controller.Audio.Enabled){Reply(false,"Enable voice before sending a question");break;}Controller.Bridge.Send(new JObject{{"type","voice.text"},{"text",(string)e["question"]}});Reply(true,"Question submitted; answer arrives separately");break;
    default:Reply(false,"Unsupported Quest test action");break;
   }}catch(Exception error){Reply(false,error.Message);}
  }
  void OnApplicationPause(bool value){paused=value;}
  void OnDestroy(){if(Link)Link.Message-=Handle;}
 }
}
