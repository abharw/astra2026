using System;
using System.IO;
using Meta.XR;
using SpatialAssembly;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.UI;

public static class BuildQuest {
 [MenuItem("Spatial Assembly/Prepare scene")]
 public static void Prepare(){
  // Register XR settings before BuildPipeline starts; otherwise OpenXR refuses late initialization.
  var openXR = AssetDatabase.LoadMainAssetAtPath("Assets/XR/Settings/OpenXR Package Settings.asset");
  var loaders = AssetDatabase.LoadMainAssetAtPath("Assets/XR/XRGeneralSettingsPerBuildTarget.asset");
  if (!openXR || !loaders) throw new Exception("XR configuration assets are missing");
  EditorBuildSettings.AddConfigObject("com.unity.xr.openxr.settings4", openXR, true);
  EditorBuildSettings.AddConfigObject("com.unity.xr.management.loader_settings", loaders, true);
  var scene=EditorSceneManager.NewScene(NewSceneSetup.EmptyScene,NewSceneMode.Single);
  PlayerSettings.companyName="Akeil";PlayerSettings.productName="Spatial Assembly";
  PlayerSettings.SetApplicationIdentifier(UnityEditor.Build.NamedBuildTarget.Android,"com.akeil.spatialassembly.quest");
  PlayerSettings.SetScriptingBackend(UnityEditor.Build.NamedBuildTarget.Android,ScriptingImplementation.IL2CPP);
  PlayerSettings.Android.targetArchitectures=AndroidArchitecture.ARM64;
  PlayerSettings.Android.minSdkVersion=AndroidSdkVersions.AndroidApiLevel32;
  PlayerSettings.Android.targetSdkVersion=AndroidSdkVersions.AndroidApiLevelAuto;
  PlayerSettings.colorSpace=ColorSpace.Linear;PlayerSettings.runInBackground=false;PlayerSettings.defaultInterfaceOrientation=UIOrientation.LandscapeLeft;
  PlayerSettings.SetGraphicsAPIs(BuildTarget.Android,new[]{UnityEngine.Rendering.GraphicsDeviceType.Vulkan});
  PlayerSettings.Android.androidTVCompatibility=false;
  var rigGO=new GameObject("Quest camera rig");var rig=rigGO.AddComponent<OVRCameraRig>();var manager=rigGO.AddComponent<OVRManager>();manager.isInsightPassthroughEnabled=true;manager.trackingOriginType=OVRManager.TrackingOrigin.FloorLevel;
  var layer=rigGO.AddComponent<OVRPassthroughLayer>();layer.overlayType=OVROverlay.OverlayType.Underlay;
  foreach(var camera in rigGO.GetComponentsInChildren<Camera>()){camera.clearFlags=CameraClearFlags.SolidColor;camera.backgroundColor=Color.clear;camera.nearClipPlane=.05f;camera.farClipPlane=30;}
  rig.centerEyeAnchor.gameObject.AddComponent<AudioListener>();
  if(UnityEngine.Object.FindObjectsByType<AudioListener>(FindObjectsSortMode.None).Length!=1)throw new Exception("Quest scene must have exactly one audio listener");
  var handGO=new GameObject("Right hand pointer");handGO.transform.SetParent(rig.rightHandAnchor,false);var hand=handGO.AddComponent<OVRHand>();var handSO=new SerializedObject(hand);handSO.FindProperty("HandType").intValue=(int)OVRHand.Hand.HandRight;handSO.ApplyModifiedPropertiesWithoutUndo();
  var services=new GameObject("Spatial Assembly services");var bridge=services.AddComponent<BridgeConnection>();var audio=services.AddComponent<RealtimeAudio>();var store=services.AddComponent<SavedAssemblies>();var controller=services.AddComponent<QuestAssemblyController>();var access=services.AddComponent<PassthroughCameraAccess>();access.CameraPosition=PassthroughCameraAccess.CameraPositionType.Left;access.RequestedResolution=new Vector2Int(1280,960);
  var depth=services.AddComponent<EnvironmentRaycastManager>();controller.Rig=rig;controller.RightHand=hand;controller.CameraAccess=access;controller.Depth=depth;controller.Bridge=bridge;controller.Audio=audio;controller.Store=store;
  var canvasGO=new GameObject("Controller guide",typeof(RectTransform),typeof(Canvas));var canvas=canvasGO.GetComponent<Canvas>();canvas.renderMode=RenderMode.WorldSpace;var rect=canvasGO.GetComponent<RectTransform>();rect.sizeDelta=new Vector2(1100,730);rect.localScale=Vector3.one*.0006f;rect.position=new Vector3(0,1.4f,1.2f);controller.Panel=rect;
  var background=new GameObject("Guide background",typeof(RectTransform),typeof(Image));background.transform.SetParent(rect,false);var bg=background.GetComponent<RectTransform>();bg.sizeDelta=rect.sizeDelta;background.GetComponent<Image>().color=new Color(.018f,.035f,.05f,.94f);
  Text(rect,"Guide title",new Vector2(0,315),new Vector2(1020,55),30,"SPATIAL ASSEMBLY • CONTROLLER GUIDE");
  controller.StatusText=Text(rect,"Status",new Vector2(0,195),new Vector2(1020,170),32,"CONNECTING\nConnecting camera and server…");
  controller.DetailText=Text(rect,"Answer and selected part",new Vector2(0,25),new Vector2(1020,150),27,"Point + trigger selects what you mean by this or that.");
  controller.HintText=Text(rect,"Controls",new Vector2(0,-200),new Vector2(1020,250),27,"Grip to grab • Trigger to select / scan / place");
  if(File.Exists("Assets/StreamingAssets/control.json")){var testGO=new GameObject("Explicit Quest test connection");var testBridge=testGO.AddComponent<BridgeConnection>();testBridge.ConfigFile="control.json";testBridge.ForegroundOnly=true;var test=testGO.AddComponent<QuestTestControl>();test.Link=testBridge;test.Controller=controller;controller.TestControl=test;}
  var light=new GameObject("Neutral model light").AddComponent<Light>();light.type=LightType.Directional;light.intensity=1.2f;light.transform.rotation=Quaternion.Euler(45,-30,0);RenderSettings.ambientLight=new Color(.65f,.68f,.72f);
  Directory.CreateDirectory("Assets/Resources/SpatialMaterials");foreach(var name in new[]{"Standard","Unlit/Color","UI/Default"}){var shader=Shader.Find(name);if(shader){var path="Assets/Resources/SpatialMaterials/"+name.Replace('/','_')+".mat";if(!AssetDatabase.LoadAssetAtPath<Material>(path))AssetDatabase.CreateAsset(new Material(shader),path);}}
  Directory.CreateDirectory("Assets/Scenes");EditorSceneManager.SaveScene(scene,"Assets/Scenes/SpatialAssembly.unity");EditorBuildSettings.scenes=new[]{new EditorBuildSettingsScene("Assets/Scenes/SpatialAssembly.unity",true)};AssetDatabase.SaveAssets();
 }
 static Text Text(Transform parent,string name,Vector2 position,Vector2 size,int font,string value){var go=new GameObject(name,typeof(RectTransform),typeof(Text));go.transform.SetParent(parent,false);var r=go.GetComponent<RectTransform>();r.anchoredPosition=position;r.sizeDelta=size;var t=go.GetComponent<Text>();t.font=Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");t.fontSize=font;t.color=Color.white;t.text=value;t.alignment=TextAnchor.UpperLeft;t.horizontalOverflow=HorizontalWrapMode.Wrap;t.verticalOverflow=VerticalWrapMode.Truncate;return t;}
 static Text Button(Transform parent,string label,Vector2 position,Action action,UnityEngine.Object receiver,string method){var t=Text(parent,label,position,new Vector2(325,70),27,label);t.alignment=TextAnchor.MiddleCenter;var image=new GameObject("Button background",typeof(RectTransform),typeof(Image));image.transform.SetParent(parent,false);image.transform.SetSiblingIndex(t.transform.GetSiblingIndex());image.GetComponent<RectTransform>().anchoredPosition=position;image.GetComponent<RectTransform>().sizeDelta=new Vector2(323,68);image.GetComponent<Image>().color=new Color(.02f,.28f,.36f,.95f);var collider=t.gameObject.AddComponent<BoxCollider>();collider.size=new Vector3(325,70,10);var button=t.gameObject.AddComponent<PersistentWorldButton>();button.Receiver=receiver;button.Method=method;return t;}
 [MenuItem("Spatial Assembly/Build Android APK")]
 public static void Build(){EditorUserBuildSettings.selectedBuildTargetGroup=BuildTargetGroup.Android;Prepare();EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android,BuildTarget.Android);var output=Environment.GetEnvironmentVariable("SPATIAL_APK")??Path.GetFullPath("../spatial-assembly-quest.apk");var report=BuildPipeline.BuildPlayer(new BuildPlayerOptions{scenes=new[]{"Assets/Scenes/SpatialAssembly.unity"},target=BuildTarget.Android,locationPathName=output,options=BuildOptions.Development});if(report.summary.result!=BuildResult.Succeeded)throw new Exception("Quest build failed: "+report.summary.result);Debug.Log("SPATIAL_APK_BUILT "+output);}
}
