using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Newtonsoft.Json;
using UnityEngine;
namespace SpatialAssembly {
 [Serializable] public class SavedEntry {public string anchorId,objectId;public AssemblyData assembly;public float[] position,rotation,scale,homePosition,homeRotation,homeScale;public float explosion;public bool extracted,hologram,inferred;}
 public class SavedAssemblies:MonoBehaviour {
  public string Status="Nothing saved yet";public event Action<AssemblyVisual> Restored;
  readonly Dictionary<string,SavedEntry> records=new();readonly List<AssemblyVisual> live=new();bool loading;float lastSave;
  string FilePath=>Path.Combine(Application.persistentDataPath,"assemblies-v2.json");
  void Start(){try{if(File.Exists(FilePath))foreach(var item in JsonConvert.DeserializeObject<List<SavedEntry>>(File.ReadAllText(FilePath)))records[item.objectId]=item;}catch(Exception e){Status="Saved data could not be read: "+e.Message;}Restore();}
  public void Register(AssemblyVisual visual){if(!live.Contains(visual))live.Add(visual);_ = PersistAnchor(visual);}
  async Task PersistAnchor(AssemblyVisual visual){try{var anchor=visual.transform.parent.GetComponent<OVRSpatialAnchor>();float deadline=Time.realtimeSinceStartup+20;while(anchor&&!anchor.Created&&Time.realtimeSinceStartup<deadline)await Task.Delay(100);if(!anchor||!anchor.Created){Status="Anchor not created; object remains session-only";return;}var result=await anchor.SaveAnchorAsync();if(!result.Success){Status="Anchor save failed; object remains session-only";return;}Capture(visual,anchor.Uuid.ToString());Write();}catch(Exception e){Status="Anchor save failed: "+e.Message;}}
  static float[] V(Vector3 v)=>new[]{v.x,v.y,v.z};static float[] Q(Quaternion q)=>new[]{q.x,q.y,q.z,q.w};static Quaternion R(float[] q)=>new Quaternion(q[0],q[1],q[2],q[3]);
  void Capture(AssemblyVisual v,string anchorId){records[v.ObjectId]=new SavedEntry{anchorId=anchorId,objectId=v.ObjectId,assembly=v.Data,position=V(v.transform.localPosition),rotation=Q(v.transform.localRotation),scale=V(v.transform.localScale),homePosition=V(v.HomePosition),homeRotation=Q(v.HomeRotation),homeScale=V(v.HomeScale),explosion=v.Explosion,extracted=v.Extracted,hologram=v.Hologram,inferred=v.ShowInferred};}
  void Update(){if(Time.unscaledTime-lastSave<3)return;lastSave=Time.unscaledTime;SaveCurrent();}
  public void SaveCurrent(){bool changed=false;foreach(var v in live){if(v&&records.TryGetValue(v.ObjectId,out var prior)){Capture(v,prior.anchorId);changed=true;}}if(changed)Write();}
  void Write(){try{var temp=FilePath+".tmp";File.WriteAllText(temp,JsonConvert.SerializeObject(records.Values.ToList()));if(File.Exists(FilePath))File.Replace(temp,FilePath,null);else File.Move(temp,FilePath);Status=$"Saved on Quest · {records.Count} objects";}catch(Exception e){Status="Save failed: "+e.Message;}}
  public async void Restore(){if(loading||records.Count==0)return;loading=true;Status="Looking for saved anchors…";try{var pending=records.Values.Where(r=>!live.Any(v=>v&&v.ObjectId==r.objectId)).ToList();var anchors=new List<OVRSpatialAnchor.UnboundAnchor>();var ids=pending.Select(r=>Guid.Parse(r.anchorId)).Distinct().ToList();var result=await OVRSpatialAnchor.LoadUnboundAnchorsAsync(ids,anchors);if(!result.Success){Status="Saved anchors unavailable; look around and Retry restore";return;}int restored=0;foreach(var unbound in anchors){if(!unbound.Localized&&!await unbound.LocalizeAsync(15))continue;foreach(var record in pending.Where(r=>r.anchorId==unbound.Uuid.ToString())){record.assembly.Validate();var root=new GameObject("Restored spatial anchor");var anchor=root.AddComponent<OVRSpatialAnchor>();unbound.BindTo(anchor);var child=new GameObject(record.assembly.name);child.transform.SetParent(root.transform,false);var v=child.AddComponent<AssemblyVisual>();v.ObjectId=record.objectId;v.Hologram=record.hologram;v.ShowInferred=record.inferred;v.Extracted=record.extracted;v.Explosion=record.explosion;v.Build(record.assembly);v.HomePosition=AssemblyData.V(record.homePosition);v.HomeRotation=R(record.homeRotation);v.HomeScale=AssemblyData.V(record.homeScale);child.transform.localPosition=AssemblyData.V(record.position);child.transform.localRotation=R(record.rotation);child.transform.localScale=AssemblyData.V(record.scale);live.Add(v);Restored?.Invoke(v);restored++;}}Status=$"Restored {restored} · unmatched anchors stay hidden";}catch(Exception e){Status="Restore failed: "+e.Message;}finally{loading=false;}}
  void OnApplicationPause(bool pause){if(pause)SaveCurrent();}void OnApplicationQuit(){SaveCurrent();}
 }
}
