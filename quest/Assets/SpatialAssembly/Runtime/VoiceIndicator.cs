using UnityEngine;
using UnityEngine.UI;

namespace SpatialAssembly {
 // Small, non-interactive status attached below the center of the wearer's view.
 public class VoiceIndicator:MonoBehaviour {
  public RealtimeAudio Audio;public BridgeConnection Bridge;public Text Label;public VoiceIndicatorGraphic Icon;public CanvasGroup Opacity;
  void Update(){
   if(!Audio||!Bridge||!Label||!Icon)return;
   string label;Color color;bool active=false;
   if(!Bridge.Connected){label="Offline";color=new Color(1f,.72f,.4f);}
   else if(!string.IsNullOrEmpty(Audio.Error)){label="Voice error";color=new Color(1f,.53f,.47f);}
   else if(Audio.AwaitingPermission){label="Mic access";color=new Color(1f,.76f,.45f);}
   else if(Audio.Starting){label="Connecting";color=new Color(1f,.8f,.49f);}
   else if(Audio.Speaking){label="Speaking";color=new Color(.52f,.86f,1f);active=true;}
   else if(Audio.Enabled){active=Audio.MicrophoneActive;label=active?"Listening":"Starting mic";color=active?new Color(.58f,.91f,.74f):new Color(1f,.8f,.49f);}
   else{label="Hold B · off";color=new Color(.8f,.83f,.85f);}
   if(Label.text!=label)Label.text=label;Label.color=color;Icon.color=color;
   Icon.SetState(active,Audio.Speaking?0:Audio.InputLevel);
   if(Opacity)Opacity.alpha=active? .94f:.84f;
  }
 }
}
