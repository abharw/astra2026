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
  public string Url,Token;
  IEnumerator Start(){using(var req=UnityWebRequest.Get(Application.streamingAssetsPath+"/connection.json")){yield return req.SendWebRequest();if(req.result!=UnityWebRequest.Result.Success){Status="Pair this headset using configure.py before building";yield break;}try{var c=JObject.Parse(req.downloadHandler.text);Url=(string)c["url"];Token=(string)c["token"];}catch{Status="Invalid pairing configuration";yield break;}}Connect();}
  public async void Connect(){
   if(Connected)return;
   try{cancel?.Cancel();socket?.Dispose();cancel=new CancellationTokenSource();socket=new ClientWebSocket();socket.Options.SetRequestHeader("Authorization","Bearer "+Token);socket.Options.KeepAliveInterval=TimeSpan.FromSeconds(15);var uri=new UriBuilder(Url){Scheme="wss",Path="/session",Query=""};if(uri.Port==80)uri.Port=443;Status="Connecting…";await socket.ConnectAsync(uri.Uri,cancel.Token);Status="Connected";_ = Receive(socket,cancel.Token);}catch(Exception e){Status="Connection failed: "+e.Message;}
  }
  async Task Receive(ClientWebSocket current,CancellationToken ct){var bytes=new byte[65536];try{while(current.State==WebSocketState.Open&&!ct.IsCancellationRequested){using var stream=new MemoryStream();WebSocketReceiveResult result;do{result=await current.ReceiveAsync(new ArraySegment<byte>(bytes),ct);if(result.MessageType==WebSocketMessageType.Close)throw new Exception("Bridge closed");stream.Write(bytes,0,result.Count);if(stream.Length>12*1024*1024)throw new Exception("Bridge message too large");}while(!result.EndOfMessage);received.Enqueue(JObject.Parse(Encoding.UTF8.GetString(stream.ToArray())));}}catch(Exception e){if(!ct.IsCancellationRequested){Status="Disconnected: "+e.Message;received.Enqueue(new JObject{{"type","disconnected"}});}}}
  public void Send(JObject message){if(Connected)outgoing.Enqueue(Encoding.UTF8.GetBytes(message.ToString(Newtonsoft.Json.Formatting.None)));}
  void Update(){while(received.TryDequeue(out var e))Message?.Invoke(e);if(!sending&&Connected&&!outgoing.IsEmpty)Drain();}
  async void Drain(){sending=true;try{while(Connected&&outgoing.TryDequeue(out var bytes))await socket.SendAsync(new ArraySegment<byte>(bytes),WebSocketMessageType.Text,true,cancel.Token);}catch(Exception e){Status=e.Message;}finally{sending=false;}}
  void OnDestroy(){cancel?.Cancel();socket?.Dispose();cancel?.Dispose();}
 }
}
