using System;
using System.IO;
using System.Linq;
using Newtonsoft.Json.Linq;
using SpatialAssembly;
using UnityEngine;
public static class GeometryChecks {
 static void Check(bool value,string message){if(!value)throw new Exception("Geometry check failed: "+message);}
 public static void Run(){
  var snapshot=new QuestAssemblyController.Snapshot{camera=new Pose(new Vector3(1,2,3),Quaternion.Euler(0,35,0)),ray00=new Vector3(-1,-1,1),ray10=new Vector3(1,-1,1),ray01=new Vector3(-1,1,1),ray11=new Vector3(1,1,1)};
  Check(Vector3.Distance(snapshot.Ray(.5f,.5f).direction,snapshot.camera.forward)<.00001f,"captured center ray");
  Check(snapshot.Ray(.5f,1).direction.y>snapshot.Ray(.5f,0).direction.y,"viewport vertical orientation");
  string path=Environment.GetEnvironmentVariable("SPATIAL_TEST_ASSEMBLY");
  if(string.IsNullOrEmpty(path))throw new Exception("Set SPATIAL_TEST_ASSEMBLY to a generated assembly JSON");
  var json=JObject.Parse(File.ReadAllText(path));var data=(json["assembly"]??json).ToObject<AssemblyData>();data.Validate();
  int count=0;foreach(var part in data.parts)foreach(var primitive in part.primitives){var mesh=Geometry.Create(primitive);Check(mesh.vertexCount>=3,"vertex count");Check(mesh.triangles.All(i=>i>=0&&i<mesh.vertexCount),"triangle indices");Check(mesh.vertices.All(v=>AssemblyData.Finite(v.x)&&AssemblyData.Finite(v.y)&&AssemblyData.Finite(v.z)),"finite vertices");UnityEngine.Object.DestroyImmediate(mesh);count++;}
  var anchor=new GameObject("check anchor");anchor.transform.SetPositionAndRotation(new Vector3(2,1,3),Quaternion.Euler(0,45,0));var child=new GameObject("check object");child.transform.SetParent(anchor.transform,false);var visual=child.AddComponent<AssemblyVisual>();visual.HomePosition=new Vector3(.1f,.2f,.3f);visual.HomeScale=Vector3.one*.7f;visual.Build(data);visual.transform.localPosition=Vector3.one*4;visual.Extracted=true;visual.SetExplosion(1);visual.ReturnHome();Check(!visual.Extracted&&visual.Explosion==0&&Vector3.Distance(visual.transform.localPosition,visual.HomePosition)<.00001f,"return preserves source local pose");UnityEngine.Object.DestroyImmediate(anchor);
  Debug.Log($"SPATIAL_GEOMETRY_CHECKS_PASSED parts={data.parts.Count} primitives={count}; captured ray orientation and return pose passed");
 }
 public static void CheckAndBuild(){Run();BuildQuest.Build();}
}
