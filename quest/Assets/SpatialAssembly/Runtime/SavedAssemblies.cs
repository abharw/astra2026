using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Newtonsoft.Json;
using UnityEngine;
namespace SpatialAssembly {
 [Serializable] public class SavedEntry {public string anchorId,objectId;public AssemblyData assembly;public float[] position,rotation,scale,homePosition,homeRotation,homeScale;public float explosion;public bool extracted,hologram,inferred,internalsRevealed;}
 public class SavedAssemblies:MonoBehaviour {
  public string Status="Nothing saved yet";public event Action<AssemblyVisual> Restored;
  readonly HashSet<string> deleted=new();public string[] SavedObjectIds=>records.Keys.ToArray();
  readonly Dictionary<string,SavedEntry> records=new();readonly List<AssemblyVisual> live=new();bool loading;int restoreEpoch;float lastSave;readonly HashSet<string> recalled=new();
  public int RecoveryFailures {get;private set;}
  string FilePath=>Path.Combine(Application.persistentDataPath,"assemblies-v2.json");
  void Start(){try{if(File.Exists(FilePath))foreach(var item in JsonConvert.DeserializeObject<List<SavedEntry>>(File.ReadAllText(FilePath)))records[item.objectId]=item;}catch(Exception e){Status="Saved data could not be read: "+e.Message;}Restore();}
  public void Register(AssemblyVisual visual){if(!live.Contains(visual))live.Add(visual);_ = PersistAnchor(visual);}
  async Task PersistAnchor(AssemblyVisual visual){try{string objectId=visual.ObjectId;var anchor=visual.transform.parent.GetComponent<OVRSpatialAnchor>();float deadline=Time.realtimeSinceStartup+20;while(anchor&&!anchor.Created&&Time.realtimeSinceStartup<deadline)await Task.Delay(100);if(!visual||deleted.Contains(visual.ObjectId))return;if(!anchor||!anchor.Created){Status="Anchor not created; object remains session-only";return;}var result=await anchor.SaveAnchorAsync();if(!result.Success){Status="Anchor save failed; object remains session-only";return;}if(deleted.Contains(objectId)){if(anchor)await anchor.EraseAnchorAsync();return;}if(!visual)return;Capture(visual,anchor.Uuid.ToString());Write();}catch(Exception e){Status="Anchor save failed: "+e.Message;}}
  static float[] V(Vector3 v)=>new[]{v.x,v.y,v.z};static float[] Q(Quaternion q)=>new[]{q.x,q.y,q.z,q.w};static Quaternion R(float[] q)=>new Quaternion(q[0],q[1],q[2],q[3]);
  void Capture(AssemblyVisual v,string anchorId){if(!v||deleted.Contains(v.ObjectId))return;records[v.ObjectId]=new SavedEntry{anchorId=anchorId,objectId=v.ObjectId,assembly=v.Data,position=V(v.transform.localPosition),rotation=Q(v.transform.localRotation),scale=V(v.transform.localScale),homePosition=V(v.HomePosition),homeRotation=Q(v.HomeRotation),homeScale=V(v.HomeScale),explosion=v.Explosion,extracted=v.Extracted,hologram=v.Hologram,inferred=v.ShowInferred,internalsRevealed=v.InternalsRevealed};}
  void Update(){if(Time.unscaledTime-lastSave<3)return;lastSave=Time.unscaledTime;SaveCurrent();}
  public void SaveCurrent(){bool changed=false;foreach(var v in live){if(v&&records.TryGetValue(v.ObjectId,out var prior)){var anchor=v.transform.parent.GetComponent<OVRSpatialAnchor>();if(!anchor||!anchor.Created||anchor.Uuid.ToString()!=prior.anchorId)continue;Capture(v,prior.anchorId);changed=true;}}if(changed)Write();}
  bool Write(){try{var temp=FilePath+".tmp";File.WriteAllText(temp,JsonConvert.SerializeObject(records.Values.ToList()));if(File.Exists(FilePath))File.Replace(temp,FilePath,null);else File.Move(temp,FilePath);Status=$"Saved on Quest · {records.Count} objects";return true;}catch(Exception e){Status="Save failed: "+e.Message;return false;}}
  public async void Restore(){
   if(loading||records.Count==0)return;int run=++restoreEpoch;loading=true;Status="Looking for saved anchors…";
   try{
    var pending=records.Values.Where(r=>!live.Any(v=>v&&v.ObjectId==r.objectId)).ToList();var anchors=new List<OVRSpatialAnchor.UnboundAnchor>();
    var ids=pending.Select(r=>Guid.Parse(r.anchorId)).Distinct().ToList();var result=await OVRSpatialAnchor.LoadUnboundAnchorsAsync(ids,anchors);
    if(run!=restoreEpoch)return;if(!result.Success){Status="Saved anchors unavailable; use Bring all here";return;}
    int restored=0;
    foreach(var unbound in anchors){
     bool localized=unbound.Localized||await unbound.LocalizeAsync(15);if(run!=restoreEpoch)return;if(!localized)continue;
     foreach(var record in pending.Where(r=>r.anchorId==unbound.Uuid.ToString())){
      if(deleted.Contains(record.objectId)||!records.ContainsKey(record.objectId)||live.Any(v=>v&&v.ObjectId==record.objectId))continue;
      record.assembly.Validate();var root=new GameObject("Restored spatial anchor");var anchor=root.AddComponent<OVRSpatialAnchor>();unbound.BindTo(anchor);
      var v=BuildSaved(record,root.transform);live.Add(v);Restored?.Invoke(v);restored++;
     }
    }Status=$"Restored {restored} · use Bring all here for missing objects";
   }catch(Exception e){if(run==restoreEpoch)Status="Restore failed: "+e.Message;}finally{if(run==restoreEpoch)loading=false;}
  }
  AssemblyVisual BuildSaved(SavedEntry record,Transform parent){
   var child=new GameObject(record.assembly.name);child.transform.SetParent(parent,false);var v=child.AddComponent<AssemblyVisual>();
   v.ObjectId=record.objectId;v.Hologram=record.hologram;v.ShowInferred=record.inferred;v.Extracted=record.extracted;v.Explosion=record.explosion;v.InternalsRevealed=record.internalsRevealed;v.Build(record.assembly);
   v.HomePosition=AssemblyData.V(record.homePosition);v.HomeRotation=R(record.homeRotation);v.HomeScale=AssemblyData.V(record.homeScale);
   child.transform.localPosition=AssemblyData.V(record.position);child.transform.localRotation=R(record.rotation);child.transform.localScale=AssemblyData.V(record.scale);return v;
  }
  public List<AssemblyVisual> RecoverMissing(Vector3 nearViewer){
   // The explicit recall supersedes asynchronous localization without losing saved identities.
   restoreEpoch++;loading=false;RecoveryFailures=0;SaveCurrent();
   try{if(File.Exists(FilePath))File.Copy(FilePath,FilePath+".before-recall",true);}catch(Exception e){Debug.LogWarning("Placement backup unavailable: "+e.Message);}
   foreach(var record in records.Values.ToArray()){
    if(deleted.Contains(record.objectId)||live.Any(v=>v&&v.ObjectId==record.objectId))continue;
    GameObject root=null;
    try{
     record.assembly.Validate();root=new GameObject("Recalled spatial anchor");root.transform.position=nearViewer;root.AddComponent<OVRSpatialAnchor>();
     var v=BuildSaved(record,root.transform);v.gameObject.SetActive(false);live.Add(v);recalled.Add(v.ObjectId);Restored?.Invoke(v);
    }catch(Exception e){RecoveryFailures++;if(root)Destroy(root);Debug.LogWarning("Saved object could not be recalled: "+e.Message);}
   }return live.Where(v=>v).ToList();
  }
  public void SaveRecall(){
   foreach(var v in live.Where(v=>v&&recalled.Contains(v.ObjectId)).ToArray()){
    // An unlocalized old home cannot be invented. The chosen recovery placement becomes its new home.
    v.HomePosition=v.transform.localPosition;v.HomeRotation=v.transform.localRotation;recalled.Remove(v.ObjectId);_ = PersistAnchor(v);
   }SaveCurrent();
  }
  public bool Delete(AssemblyVisual visual){
   if(!visual)return false;string id=visual.ObjectId;records.TryGetValue(id,out var prior);records.Remove(id);
   if(!Write()){if(prior!=null)records[id]=prior;return false;}
   deleted.Add(id);live.RemoveAll(v=>!v||v.ObjectId==id);var root=visual.transform.parent.gameObject;root.SetActive(false);visual.ReleaseImportedAssets();_ = EraseRemovedAnchor(root);return true;
  }
  async Task EraseRemovedAnchor(GameObject root){try{var anchor=root.GetComponent<OVRSpatialAnchor>();if(anchor&&anchor.Created)await anchor.EraseAnchorAsync();}catch{Status="Object deleted; unused anchor cleanup failed";}finally{if(root)Destroy(root);}}
  void OnApplicationPause(bool pause){if(pause)SaveCurrent();}void OnApplicationQuit(){SaveCurrent();}
 }
}
