using UnityEngine;
using UnityEngine.UI;

namespace SpatialAssembly {
 public class VoiceIndicatorGraphic:MaskableGraphic {
  public bool Pill;bool active;float level;
  public void SetState(bool enabled,float input){float next=Mathf.Clamp01(input*5);if(active==enabled&&Mathf.Abs(next-level)<.04f)return;active=enabled;level=next;SetVerticesDirty();}
  protected override void OnPopulateMesh(VertexHelper vh){
   vh.Clear();var c=(Color32)color;
   if(Pill){var r=rectTransform.rect;float radius=r.height*.5f,offset=r.width*.5f-radius;vh.AddVert(Vector3.zero,c,Vector2.zero);for(int j=0;j<=40;j++){float a=j*Mathf.PI*2/40;var v=new Vector2(Mathf.Cos(a)*radius+(Mathf.Cos(a)>=0?offset:-offset),Mathf.Sin(a)*radius);vh.AddVert(v,c,Vector2.zero);if(j>0)vh.AddTriangle(0,j,j+1);}return;}

   // Capsule microphone, receiver arc and stand. The slash makes Off distinct without color.
   Quad(vh,-3,-2,3,5,c);Disc(vh,new Vector2(0,5),3,c);Disc(vh,new Vector2(0,-2),3,c);
   for(int i=0;i<16;i++){float a=Mathf.PI+i*Mathf.PI/16,b=Mathf.PI+(i+1)*Mathf.PI/16;Line(vh,new Vector2(Mathf.Cos(a)*6,Mathf.Sin(a)*6-1),new Vector2(Mathf.Cos(b)*6,Mathf.Sin(b)*6-1),1.3f,c);}
   Line(vh,new Vector2(-6,-1),new Vector2(-6,2),1.3f,c);Line(vh,new Vector2(6,-1),new Vector2(6,2),1.3f,c);
   Quad(vh,-.7f,-10,.7f,-7,c);Quad(vh,-3,-11,3,-9.7f,c);
   if(!active)Line(vh,new Vector2(-9,10),new Vector2(9,-11),1.5f,c);
   else if(level>.05f){float h=2+level*6;Quad(vh,10,-h,11.4f,h,c);}
  }
  static void Quad(VertexHelper vh,float x0,float y0,float x1,float y1,Color32 c){int i=vh.currentVertCount;vh.AddVert(new Vector3(x0,y0),c,Vector2.zero);vh.AddVert(new Vector3(x0,y1),c,Vector2.zero);vh.AddVert(new Vector3(x1,y1),c,Vector2.zero);vh.AddVert(new Vector3(x1,y0),c,Vector2.zero);vh.AddTriangle(i,i+1,i+2);vh.AddTriangle(i,i+2,i+3);}
  static void Line(VertexHelper vh,Vector2 a,Vector2 b,float width,Color32 c){Vector2 n=new Vector2(-(b-a).y,(b-a).x).normalized*width*.5f;int i=vh.currentVertCount;vh.AddVert(a-n,c,Vector2.zero);vh.AddVert(a+n,c,Vector2.zero);vh.AddVert(b+n,c,Vector2.zero);vh.AddVert(b-n,c,Vector2.zero);vh.AddTriangle(i,i+1,i+2);vh.AddTriangle(i,i+2,i+3);}
  static void Disc(VertexHelper vh,Vector2 center,float radius,Color32 c){int first=vh.currentVertCount;vh.AddVert(center,c,Vector2.zero);for(int j=0;j<=20;j++){float a=j*Mathf.PI*2/20;vh.AddVert(center+new Vector2(Mathf.Cos(a),Mathf.Sin(a))*radius,c,Vector2.zero);if(j>0)vh.AddTriangle(first,first+j,first+j+1);}}
 }
}
