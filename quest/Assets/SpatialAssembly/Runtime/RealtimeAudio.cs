using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using UnityEngine;
#if UNITY_ANDROID
using UnityEngine.Android;
#endif
namespace SpatialAssembly {
 public class RealtimeAudio:MonoBehaviour {
  public bool Enabled {get;private set;}public string Status="Voice off";
  public BridgeConnection Bridge;
  public string Error {get;private set;}="";
  public bool AwaitingPermission=>awaitingPermission;public bool MicrophoneActive=>Enabled&&mic&&Microphone.IsRecording(null)&&Microphone.GetPosition(null)>0;
  public bool Starting=>starting;public float InputLevel {get;private set;}
  public bool Speaking {get {lock(audioLock)return samples.Count>0;}}
  class PlaybackMark {public string id;public long end;public float reached;}readonly Queue<PlaybackMark> playbackMarks=new();long queuedSamples,playedSamples;
  float startedAt;AudioClip mic;AudioSource speaker;int readPosition;bool awaitingPermission,starting;readonly Queue<float> samples=new();readonly object audioLock=new();
  void Awake(){speaker=gameObject.AddComponent<AudioSource>();speaker.spatialBlend=0;speaker.loop=true;speaker.clip=AudioClip.Create("Realtime streamed audio",2400,1,24000,true,ReadAudio);speaker.Play();}
  public void Toggle(){if(Enabled||starting){Stop();return;}Error="";
#if UNITY_ANDROID && !UNITY_EDITOR
   if(!Permission.HasUserAuthorizedPermission(Permission.Microphone)){awaitingPermission=true;Permission.RequestUserPermission(Permission.Microphone);Status="Allow microphone permission to start voice";return;}
#endif
   if(!Bridge.Connected){Status="Connect the bridge first";return;}starting=true;startedAt=Time.realtimeSinceStartup;Status="Starting voice…";Bridge.Send(new JObject{{"type","voice.start"}});
  }
  public void OnMessage(JObject e){switch((string)e["type"]){case "voice.ready":if(!starting)return;mic=Microphone.Start(null,true,10,24000);if(!mic){Stop();Error="Microphone unavailable. Press B to retry.";Status="Voice failed";return;}readPosition=0;Enabled=true;starting=false;Status="Listening";break;case "voice.audio.done":lock(audioLock)playbackMarks.Enqueue(new PlaybackMark{id=(string)e["response_id"],end=queuedSamples});break;case "voice.audio":var data=Convert.FromBase64String((string)e["audio"]);lock(audioLock){for(int i=0;i+1<data.Length;i+=2){if(samples.Count>24000*30){samples.Dequeue();playedSamples++;}queuedSamples++;samples.Enqueue((short)(data[i]|data[i+1]<<8)/32768f);}}break;case "voice.speech_started":ClearPlayback();break;case "voice.error":Stop();var message=(string)e["message"]??"Voice service failed";Error=message.Contains("API key")?"Voice authentication failed. Check the Mac bridge connection.":message;Status="Voice failed";break;case "voice.closed":case "disconnected":Stop(false);break;}}
  public void InterruptPlayback(){ClearPlayback();if(Bridge)Bridge.Send(new JObject{{"type","voice.interrupt"}});}
  void ClearPlayback(){lock(audioLock){samples.Clear();playbackMarks.Clear();queuedSamples=playedSamples=0;}}
  void ReadAudio(float[] data){lock(audioLock){for(int i=0;i<data.Length;i++){if(samples.Count>0){data[i]=samples.Dequeue();playedSamples++;}else data[i]=0;}}}
  void Update(){
   if(starting&&Time.realtimeSinceStartup-startedAt>25){Stop();Error="Voice connection timed out. Press B to retry.";Status="Voice failed";}
   string completed=null;lock(audioLock){if(playbackMarks.Count>0){var mark=playbackMarks.Peek();if(playedSamples>=mark.end){if(mark.reached==0)mark.reached=Time.realtimeSinceStartup;else if(Time.realtimeSinceStartup-mark.reached>.3f)completed=playbackMarks.Dequeue().id;}}}if(completed!=null)Bridge.Send(new JObject{{"type","voice.playback.ended"},{"response_id",completed}});
#if UNITY_ANDROID && !UNITY_EDITOR
   if(awaitingPermission&&Permission.HasUserAuthorizedPermission(Permission.Microphone)){awaitingPermission=false;Toggle();}
#endif
   if(!Enabled||!mic)return;var pos=Microphone.GetPosition(null);if(pos<0)return;var count=(pos-readPosition+mic.samples)%mic.samples;if(count<mic.frequency/50)return;
   var input=new float[count*mic.channels];mic.GetData(input,readPosition);float peak=0;foreach(var value in input)peak=Mathf.Max(peak,Mathf.Abs(value));InputLevel=peak;readPosition=pos;int outputCount=Mathf.FloorToInt(count*24000f/mic.frequency);var bytes=new byte[outputCount*2];for(int i=0;i<outputCount;i++){int offset=Mathf.Min(count-1,Mathf.FloorToInt(i*mic.frequency/24000f))*mic.channels;float value=0;for(int c=0;c<mic.channels;c++)value+=input[offset+c];short pcm=(short)(Mathf.Clamp(value/mic.channels,-1,1)*32767);bytes[i*2]=(byte)pcm;bytes[i*2+1]=(byte)(pcm>>8);}Bridge.Send(new JObject{{"type","voice.audio"},{"audio",Convert.ToBase64String(bytes)}});
  }
  public void Stop(bool notify=true){ClearPlayback();awaitingPermission=false;starting=false;Enabled=false;InputLevel=0;if(mic){Microphone.End(null);Destroy(mic);mic=null;}lock(audioLock)samples.Clear();if(notify&&Bridge)Bridge.Send(new JObject{{"type","voice.stop"}});Status="Voice off";}
  void OnApplicationPause(bool paused){if(paused)Stop();}void OnDestroy(){Stop();if(speaker&&speaker.clip)Destroy(speaker.clip);}
 }
}
