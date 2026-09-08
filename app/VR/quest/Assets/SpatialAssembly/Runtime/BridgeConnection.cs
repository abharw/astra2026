using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;
using UnityEngine.Networking;
using System.Collections;

namespace SpatialAssembly {
 public class BridgeConnection:MonoBehaviour {
  public bool Connected=>socket?.State==WebSocketState.Open;public string Status="Connecting…";
  public event Action<JObject> Message;
  ClientWebSocket socket;CancellationTokenSource cancel;readonly ConcurrentQueue<JObject> received=new();readonly ConcurrentQueue<byte[]> outgoing=new();bool sending;
  public string Url,Token;public string ConfigFile="connection.json";public bool ForegroundOnly;public bool UserEnabled=true;bool paused,connecting,configured,destroyed;float retryAt;int retryCount;
  IEnumerator Start(){using(var req=UnityWebRequest.Get(Application.streamingAssetsPath+"/"+ConfigFile)){yield return req.SendWebRequest();if(req.result!=UnityWebRequest.Result.Success){Status="Pair this headset using configure.py before building";yield break;}try{var c=JObject.Parse(req.downloadHandler.text);Url=(string)c["url"];Token=(string)c["token"];}catch{Status="Invalid pairing configuration";yield break;}}configured=true;if(!UserEnabled)Status="Off";Connect();}
  public async void Connect(){
   if(destroyed||!configured||connecting||!UserEnabled||Connected||(ForegroundOnly&&paused))return;
   connecting=true;ClientWebSocket current=null;
   try{cancel?.Cancel();socket?.Dispose();cancel?.Dispose();while(outgoing.TryDequeue(out _)){}while(received.TryDequeue(out _)){}cancel=new CancellationTokenSource();current=new ClientWebSocket();socket=current;current.Options.SetRequestHeader("Authorization","Bearer "+Token);current.Options.KeepAliveInterval=TimeSpan.FromSeconds(15);var uri=new UriBuilder(Url){Scheme="wss",Path="/session",Query=""};if(uri.Port==80)uri.Port=443;Status="Connecting…";await current.ConnectAsync(uri.Uri,cancel.Token);retryCount=0;Status="Connected";_ = Receive(current,cancel.Token);}catch(Exception e){if(!destroyed&&UserEnabled){Status="Connection failed: "+e.Message;current?.Dispose();}}finally{connecting=false;retryAt=Time.realtimeSinceStartup+Mathf.Min(15,1<<Mathf.Min(retryCount++,4));}
  }
  async Task Receive(ClientWebSocket current,CancellationToken ct){var bytes=new byte[65536];try{while(current.State==WebSocketState.Open&&!ct.IsCancellationRequested){using var stream=new MemoryStream();WebSocketReceiveResult result;do{result=await current.ReceiveAsync(new ArraySegment<byte>(bytes),ct);if(result.MessageType==WebSocketMessageType.Close)throw new Exception("Bridge closed");stream.Write(bytes,0,result.Count);if(stream.Length>12*1024*1024)throw new Exception("Bridge message too large");}while(!result.EndOfMessage);received.Enqueue(JObject.Parse(Encoding.UTF8.GetString(stream.ToArray())));}}catch(Exception e){if(!ct.IsCancellationRequested&&current==socket){current.Abort();retryAt=Time.realtimeSinceStartup+2;Status="Disconnected: "+e.Message;received.Enqueue(new JObject{{"type","disconnected"}});}}}
  public void Send(JObject message){if(Connected)outgoing.Enqueue(Encoding.UTF8.GetBytes(message.ToString(Newtonsoft.Json.Formatting.None)));}
  void Update(){while(received.TryDequeue(out var e))Message?.Invoke(e);if(configured&&!destroyed&&UserEnabled&&!connecting&&!Connected&&(!ForegroundOnly||!paused)&&Time.realtimeSinceStartup>=retryAt)Connect();if(!sending&&Connected&&!outgoing.IsEmpty)Drain();}
  async void Drain(){sending=true;var current=socket;var ct=cancel.Token;try{while(current==socket&&current.State==WebSocketState.Open&&outgoing.TryDequeue(out var bytes))await current.SendAsync(new ArraySegment<byte>(bytes),WebSocketMessageType.Text,true,ct);}catch(Exception e){if(current==socket&&!ct.IsCancellationRequested){current.Abort();Status=e.Message;received.Enqueue(new JObject{{"type","disconnected"}});}}finally{sending=false;}}
  public void SetEnabled(bool value){UserEnabled=value;if(value)Connect();else{cancel?.Cancel();socket?.Dispose();Status="Test connection off";}}
  void OnApplicationPause(bool value){paused=value;if(ForegroundOnly){if(value){cancel?.Cancel();socket?.Dispose();Status="Paused";}else if(!string.IsNullOrEmpty(Url))Connect();}}
  void OnDestroy(){destroyed=true;cancel?.Cancel();socket?.Dispose();cancel?.Dispose();}
 }
}
