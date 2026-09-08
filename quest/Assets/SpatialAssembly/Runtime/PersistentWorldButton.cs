using UnityEngine;
namespace SpatialAssembly {
 public class PersistentWorldButton:WorldButton {
  public Object Receiver; public string Method;
  void Awake(){Action=()=>{if(Receiver is Component component)component.SendMessage(Method,SendMessageOptions.RequireReceiver);};}
 }
}
