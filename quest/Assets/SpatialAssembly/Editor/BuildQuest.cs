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
  var canvasGO=new GameObject("Assembly controls",typeof(RectTransform),typeof(Canvas));var canvas=canvasGO.GetComponent<Canvas>();canvas.renderMode=RenderMode.WorldSpace;var rect=canvasGO.GetComponent<RectTransform>();rect.sizeDelta=new Vector2(1100,920);rect.localScale=Vector3.one*.0008f;rect.position=new Vector3(0,1.4f,1.2f);controller.Panel=rect;
  var background=new GameObject("Panel background",typeof(RectTransform),typeof(Image));background.transform.SetParent(rect,false);var bg=background.GetComponent<RectTransform>();bg.sizeDelta=rect.sizeDelta;background.GetComponent<Image>().color=new Color(.018f,.035f,.05f,.98f);
  var backdrop=background.AddComponent<BoxCollider>();backdrop.size=new Vector3(1100,920,4);backdrop.center=new Vector3(0,0,8);background.AddComponent<PanelHandle>();
  var title=Text(rect,"Move panel",new Vector2(0,405),new Vector2(1020,65),28,"SPATIAL ASSEMBLY     •     Hold trigger here to move");title.gameObject.AddComponent<PanelHandle>();title.gameObject.AddComponent<BoxCollider>().size=new Vector3(1020,65,10);
  controller.StatusText=Text(rect,"Status",new Vector2(0,265),new Vector2(1020,195),32,"CONNECTING\nConnecting camera and server…");
  controller.DetailText=Text(rect,"Answer and selected part",new Vector2(0,65),new Vector2(1020,180),28,"Your answer or selected part will appear here.");
  controller.HintText=Text(rect,"Controls help",new Vector2(0,-100),new Vector2(1020,110),24,"Hold grip over panel to move • left stick click: bring panel here");
  Button(rect,"Reconstruct",new Vector2(-350,-220),()=>controller.Reconstruct(),controller,"Reconstruct");
  controller.VoiceButton=Button(rect,"Start voice",new Vector2(0,-220),()=>audio.Toggle(),audio,"Toggle");
  Button(rect,"Cancel scan",new Vector2(350,-220),()=>controller.Cancel(),controller,"Cancel");
  controller.PullButton=Button(rect,"Pull object",new Vector2(-350,-305),()=>controller.PullOrReturn(),controller,"PullOrReturn");
  Button(rect,"Next part",new Vector2(0,-305),()=>controller.ExplainNext(),controller,"ExplainNext");
  Button(rect,"Improve model",new Vector2(350,-305),()=>controller.Refine(),controller,"Refine");
  Button(rect,"Restore saved",new Vector2(-350,-390),()=>store.Restore(),store,"Restore");
  Button(rect,"Panel here",new Vector2(0,-390),()=>controller.PositionPanel(),controller,"PositionPanel");
  Button(rect,"Reconnect",new Vector2(350,-390),()=>bridge.Connect(),bridge,"Connect");
  var light=new GameObject("Neutral model light").AddComponent<Light>();light.type=LightType.Directional;light.intensity=1.2f;light.transform.rotation=Quaternion.Euler(45,-30,0);RenderSettings.ambientLight=new Color(.65f,.68f,.72f);
  Directory.CreateDirectory("Assets/Resources/SpatialMaterials");foreach(var name in new[]{"Standard","Unlit/Color","UI/Default"}){var shader=Shader.Find(name);if(shader){var path="Assets/Resources/SpatialMaterials/"+name.Replace('/','_')+".mat";if(!AssetDatabase.LoadAssetAtPath<Material>(path))AssetDatabase.CreateAsset(new Material(shader),path);}}
  Directory.CreateDirectory("Assets/Scenes");EditorSceneManager.SaveScene(scene,"Assets/Scenes/SpatialAssembly.unity");EditorBuildSettings.scenes=new[]{new EditorBuildSettingsScene("Assets/Scenes/SpatialAssembly.unity",true)};AssetDatabase.SaveAssets();
 }
 static Text Text(Transform parent,string name,Vector2 position,Vector2 size,int font,string value){var go=new GameObject(name,typeof(RectTransform),typeof(Text));go.transform.SetParent(parent,false);var r=go.GetComponent<RectTransform>();r.anchoredPosition=position;r.sizeDelta=size;var t=go.GetComponent<Text>();t.font=Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");t.fontSize=font;t.color=Color.white;t.text=value;t.alignment=TextAnchor.UpperLeft;t.horizontalOverflow=HorizontalWrapMode.Wrap;t.verticalOverflow=VerticalWrapMode.Truncate;return t;}
 static Text Button(Transform parent,string label,Vector2 position,Action action,UnityEngine.Object receiver,string method){var t=Text(parent,label,position,new Vector2(325,70),27,label);t.alignment=TextAnchor.MiddleCenter;var image=new GameObject("Button background",typeof(RectTransform),typeof(Image));image.transform.SetParent(parent,false);image.transform.SetSiblingIndex(t.transform.GetSiblingIndex());image.GetComponent<RectTransform>().anchoredPosition=position;image.GetComponent<RectTransform>().sizeDelta=new Vector2(323,68);image.GetComponent<Image>().color=new Color(.02f,.28f,.36f,.95f);var collider=t.gameObject.AddComponent<BoxCollider>();collider.size=new Vector3(325,70,10);var button=t.gameObject.AddComponent<PersistentWorldButton>();button.Receiver=receiver;button.Method=method;return t;}
 [MenuItem("Spatial Assembly/Build Android APK")]
 public static void Build(){EditorUserBuildSettings.selectedBuildTargetGroup=BuildTargetGroup.Android;Prepare();EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android,BuildTarget.Android);var output=Environment.GetEnvironmentVariable("SPATIAL_APK")??Path.GetFullPath("../spatial-assembly-quest.apk");var report=BuildPipeline.BuildPlayer(new BuildPlayerOptions{scenes=new[]{"Assets/Scenes/SpatialAssembly.unity"},target=BuildTarget.Android,locationPathName=output,options=BuildOptions.Development});if(report.summary.result!=BuildResult.Succeeded)throw new Exception("Quest build failed: "+report.summary.result);Debug.Log("SPATIAL_APK_BUILT "+output);}
}
