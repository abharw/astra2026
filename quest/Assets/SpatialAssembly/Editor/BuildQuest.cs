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
  QualitySettings.antiAliasing=4;PlayerSettings.colorSpace=ColorSpace.Linear;PlayerSettings.runInBackground=false;PlayerSettings.defaultInterfaceOrientation=UIOrientation.LandscapeLeft;
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
  CreateVoiceIndicator(rig.centerEyeAnchor,audio,bridge);
  var rack=services.AddComponent<RackWorld>();rack.Controller=controller;controller.Rack=rack;
  // The wearer requested an unobstructed scene. Controller and voice input do
  // not depend on the former black guide canvas or its text components.
  if(File.Exists("Assets/StreamingAssets/control.json")){var testGO=new GameObject("Explicit Quest test connection");var testBridge=testGO.AddComponent<BridgeConnection>();testBridge.ConfigFile="control.json";testBridge.ForegroundOnly=true;testBridge.UserEnabled=false;var test=testGO.AddComponent<QuestTestControl>();test.Link=testBridge;test.Controller=controller;controller.TestControl=test;}
  var light=new GameObject("Neutral model light").AddComponent<Light>();light.type=LightType.Directional;light.intensity=1.2f;light.transform.rotation=Quaternion.Euler(45,-30,0);RenderSettings.ambientLight=new Color(.65f,.68f,.72f);
  Directory.CreateDirectory("Assets/Resources/SpatialMaterials");foreach(var name in new[]{"Standard","Unlit/Color","UI/Default"}){var shader=Shader.Find(name);if(shader){var path="Assets/Resources/SpatialMaterials/"+name.Replace('/','_')+".mat";if(!AssetDatabase.LoadAssetAtPath<Material>(path))AssetDatabase.CreateAsset(new Material(shader),path);}}
  Directory.CreateDirectory("Assets/Scenes");EditorSceneManager.SaveScene(scene,"Assets/Scenes/SpatialAssembly.unity");EditorBuildSettings.scenes=new[]{new EditorBuildSettingsScene("Assets/Scenes/SpatialAssembly.unity",true)};AssetDatabase.SaveAssets();
 }
 static void CreateVoiceIndicator(Transform head,RealtimeAudio audio,BridgeConnection bridge){
  var go=new GameObject("Voice status",typeof(RectTransform),typeof(Canvas),typeof(CanvasGroup));go.transform.SetParent(head,false);go.transform.localPosition=new Vector3(.11f,-.20f,.9f);go.transform.localScale=Vector3.one*.0008f;
  go.GetComponent<RectTransform>().sizeDelta=new Vector2(148,36);var canvas=go.GetComponent<Canvas>();canvas.renderMode=RenderMode.WorldSpace;canvas.sortingOrder=100;
  var background=new GameObject("Quiet background",typeof(RectTransform),typeof(VoiceIndicatorGraphic));background.transform.SetParent(go.transform,false);background.GetComponent<RectTransform>().sizeDelta=new Vector2(148,36);var image=background.GetComponent<VoiceIndicatorGraphic>();image.Pill=true;image.color=new Color(.025f,.04f,.045f,.9f);image.raycastTarget=false;
  var iconGO=new GameObject("Microphone",typeof(RectTransform),typeof(VoiceIndicatorGraphic));iconGO.transform.SetParent(go.transform,false);iconGO.GetComponent<RectTransform>().anchoredPosition=new Vector2(-53,1);iconGO.GetComponent<RectTransform>().sizeDelta=new Vector2(25,25);var icon=iconGO.GetComponent<VoiceIndicatorGraphic>();icon.raycastTarget=false;
  var label=Text(go.transform,"Voice state",new Vector2(15,0),new Vector2(106,30),16,"Off");label.alignment=TextAnchor.MiddleLeft;label.raycastTarget=false;
  var state=go.AddComponent<VoiceIndicator>();state.Audio=audio;state.Bridge=bridge;state.Label=label;state.Icon=icon;state.Opacity=go.GetComponent<CanvasGroup>();state.Opacity.blocksRaycasts=false;state.Opacity.interactable=false;
 }
 static Text Text(Transform parent,string name,Vector2 position,Vector2 size,int font,string value){var go=new GameObject(name,typeof(RectTransform),typeof(Text));go.transform.SetParent(parent,false);var r=go.GetComponent<RectTransform>();r.anchoredPosition=position;r.sizeDelta=size;var t=go.GetComponent<Text>();t.font=Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");t.fontSize=font;t.color=Color.white;t.text=value;t.alignment=TextAnchor.UpperLeft;t.horizontalOverflow=HorizontalWrapMode.Wrap;t.verticalOverflow=VerticalWrapMode.Truncate;return t;}
 static Text Button(Transform parent,string label,Vector2 position,Action action,UnityEngine.Object receiver,string method){var t=Text(parent,label,position,new Vector2(325,70),27,label);t.alignment=TextAnchor.MiddleCenter;var image=new GameObject("Button background",typeof(RectTransform),typeof(Image));image.transform.SetParent(parent,false);image.transform.SetSiblingIndex(t.transform.GetSiblingIndex());image.GetComponent<RectTransform>().anchoredPosition=position;image.GetComponent<RectTransform>().sizeDelta=new Vector2(323,68);image.GetComponent<Image>().color=new Color(.02f,.28f,.36f,.95f);var collider=t.gameObject.AddComponent<BoxCollider>();collider.size=new Vector3(325,70,10);var button=t.gameObject.AddComponent<PersistentWorldButton>();button.Receiver=receiver;button.Method=method;return t;}
 [MenuItem("Spatial Assembly/Build Android APK")]
 public static void Build(){EditorUserBuildSettings.selectedBuildTargetGroup=BuildTargetGroup.Android;Prepare();EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android,BuildTarget.Android);var output=Environment.GetEnvironmentVariable("SPATIAL_APK")??Path.GetFullPath("../spatial-assembly-quest.apk");var report=BuildPipeline.BuildPlayer(new BuildPlayerOptions{scenes=new[]{"Assets/Scenes/SpatialAssembly.unity"},target=BuildTarget.Android,locationPathName=output,options=BuildOptions.Development});if(report.summary.result!=BuildResult.Succeeded)throw new Exception("Quest build failed: "+report.summary.result);Debug.Log("SPATIAL_APK_BUILT "+output);}
}
