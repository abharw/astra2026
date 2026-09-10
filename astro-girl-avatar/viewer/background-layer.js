import * as THREE from 'three';

/** Render scenery into the same canvas so captureStream/OBS includes it. */
export function createBackgroundLayer(renderer){
 const scene=new THREE.Scene(),camera=new THREE.OrthographicCamera(-1,1,1,-1,0,10);camera.position.z=2;
 const geometry=new THREE.PlaneGeometry(2,2),loader=new THREE.TextureLoader();
 let previous=null,incoming=null,url=null,version=0,progress=1;
 const reduced=matchMedia('(prefers-reduced-motion: reduce)').matches;
 const dispose=mesh=>{if(!mesh)return;scene.remove(mesh);mesh.material.map.dispose();mesh.material.dispose()};
 function make(texture){texture.colorSpace=THREE.SRGBColorSpace;const material=new THREE.MeshBasicMaterial({map:texture,transparent:true,depthTest:false,depthWrite:false,toneMapped:false,opacity:0});const mesh=new THREE.Mesh(geometry,material);mesh.userData.aspect=texture.image.width/texture.image.height;scene.add(mesh);return mesh}
 async function setURL(next){
  if(next===url)return;url=next;const current=++version;
  let texture=null;if(next)texture=await loader.loadAsync(next);
  if(version!==current){texture?.dispose();return}
  dispose(previous);previous=incoming;incoming=texture?make(texture):null;
  if(previous){previous.renderOrder=0;previous.material.opacity=1}if(incoming)incoming.renderOrder=1;
  progress=reduced?1:0;
 }
 function render(width,height,dt){
  progress=Math.min(1,progress+dt/1.2);const aspect=width/Math.max(1,height);
  for(const mesh of [previous,incoming])if(mesh){const ratio=mesh.userData.aspect/aspect;mesh.scale.set(Math.max(1,ratio),Math.max(1,1/ratio),1)}
  if(previous)previous.material.opacity=incoming?1:1-progress;
  if(incoming)incoming.material.opacity=progress;
  if(progress===1&&previous){dispose(previous);previous=null}
  if(incoming||previous)renderer.render(scene,camera);
 }
 return {setURL,render};
}
