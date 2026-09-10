import * as THREE from 'three';
import {GLTFLoader} from 'three/addons/loaders/GLTFLoader.js';
import {RoomEnvironment} from 'three/addons/environments/RoomEnvironment.js';
import {composeWeights,cloneDefault} from './state.js';
const container=document.querySelector('#viewport');
const stage=document.body.dataset.stage==='true';
const params=new URLSearchParams(location.search);
const scene=new THREE.Scene();
const renderer=new THREE.WebGLRenderer({antialias:true,alpha:true,preserveDrawingBuffer:true});
renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.toneMapping=THREE.AgXToneMapping;renderer.toneMappingExposure=.95;
container.appendChild(renderer.domElement);renderer.domElement.setAttribute('aria-label','Live 3D Astro-inspired girl avatar');
const pmrem=new THREE.PMREMGenerator(renderer);const env=new RoomEnvironment();const envmap=pmrem.fromScene(env,.04);scene.environment=envmap.texture;env.dispose();pmrem.dispose();
scene.add(new THREE.HemisphereLight(0xeaf3ff,0xb9b4a3,.5));
const key=new THREE.DirectionalLight(0xffead8,1.2);key.position.set(-3,5,6);scene.add(key);
const fill=new THREE.DirectionalLight(0xc8e4ff,.35);fill.position.set(4,3,2);scene.add(fill);
const rim=new THREE.DirectionalLight(0xffffff,1);rim.position.set(2,4,-3);scene.add(rim);
const camera=new THREE.PerspectiveCamera(30,1,.1,100);
let framing=stage?'portrait':'full',model,head,headRest,targetState=cloneDefault(),manifest;
let mixer,actions={},motionSequence=-1,activeMotion='idle',talkWeight=0,liveAudioLevel=null,lastSpeechTime=-1,lastShownMotion='';
const gestureWeights={};
const bindings=new Map(),weights={};let time=0,previous=performance.now();
function frame(){const portrait=framing==='portrait';const aspect=container.clientWidth/Math.max(1,container.clientHeight);camera.aspect=aspect;const height=portrait?2.35:4.25;const distance=height/(2*Math.tan(THREE.MathUtils.degToRad(camera.fov/2)));camera.position.set(portrait?0:.18,portrait?2.65:2.0,distance/Math.min(1,aspect));camera.lookAt(0,portrait?2.60:1.87,0);camera.updateProjectionMatrix();renderer.setSize(container.clientWidth,container.clientHeight,false)}
new ResizeObserver(frame).observe(container);
function worldHeadRotation(yaw,pitch,roll){
 if(!head)return;head.parent.updateWorldMatrix(true,false);const parent=head.parent.getWorldQuaternion(new THREE.Quaternion());const worldDelta=new THREE.Quaternion().setFromEuler(new THREE.Euler(pitch,yaw,roll,'YXZ'));
 head.quaternion.copy(parent.clone().invert().multiply(worldDelta).multiply(parent).multiply(head.quaternion.clone()));
}
const ready=(async()=>{
 manifest=await fetch('/assets/character.json').then(r=>r.json());const gltf=await new GLTFLoader().loadAsync('/assets/astra-girl.glb');model=gltf.scene;scene.add(model);
 model.traverse(o=>{
  if(o.isMesh){o.frustumCulled=false;if(o.material){o.material.envMapIntensity=.35}for(const [name,index]of Object.entries(o.morphTargetDictionary||{})){if(!bindings.has(name))bindings.set(name,[]);bindings.get(name).push({mesh:o,index})}}
  if(o.isBone&&o.name==='head'){head=o;headRest=o.quaternion.clone()}
 });
 const missing=manifest.controls.filter(k=>!bindings.has(k));if(missing.length)throw new Error('Missing exported facial controls: '+missing.join(', '));
 mixer=new THREE.AnimationMixer(model);
 for(const [name,meta]of Object.entries(manifest.motions)){
  const clip=gltf.animations.find(c=>c.name===meta.clip);if(!clip)throw new Error('Missing motion: '+meta.clip);
  actions[name]=mixer.clipAction(clip).play();actions[name].setEffectiveWeight(name==='idle'?1:0);
 }
 frame();document.body.dataset.loaded='true';document.dispatchEvent(new CustomEvent('avatar-ready',{detail:manifest}));return manifest;
})();
ready.catch(e=>{document.querySelector('#loading').textContent='Could not load avatar: '+e.message;document.body.dataset.error=e.message;console.error(e)});
const events=new EventSource('/events');events.onmessage=e=>{targetState=JSON.parse(e.data);document.dispatchEvent(new CustomEvent('avatar-state',{detail:targetState}))};events.onerror=()=>document.dispatchEvent(new Event('avatar-disconnected'));
function tick(now){const dt=Math.min(.05,(now-previous)/1000);previous=now;time+=dt;
 if(model&&manifest){
  const phase=(time+1.3)%4.6;const autoBlink=phase>4.28?Math.sin(Math.PI*(phase-4.28)/.32):0;
  const desired=composeWeights(targetState,manifest,Math.max(0,autoBlink),liveAudioLevel);
  for(const name of manifest.controls){const speed=name.startsWith('eyeBlink')?35:16;weights[name]=(weights[name]||0)+(desired[name]-(weights[name]||0))*(1-Math.exp(-dt*speed));for(const b of bindings.get(name)||[])b.mesh.morphTargetInfluences[b.index]=weights[name]}
  const idle=targetState.idle,motion=targetState.motion;
  if(motion.sequence!==motionSequence){
   motionSequence=motion.sequence;activeMotion=motion.name;const action=actions[activeMotion];
   action.reset().setLoop(motion.loop?THREE.LoopRepeat:THREE.LoopOnce,motion.loop?Infinity:1);action.clampWhenFinished=true;action.timeScale=motion.speed;
   const elapsed=Math.max(0,(Date.now()-motion.startedAt)/1000)*motion.speed;
   action.time=motion.loop?elapsed%action.getClip().duration:Math.min(elapsed,action.getClip().duration);action.play();
  }
  const age=(Date.now()-motion.startedAt)/1000*motion.speed;
  const active=activeMotion!=='idle'&&(motion.loop||age<actions[activeMotion].getClip().duration);
  const blend=1-Math.exp(-dt*9);let gestureWeight=0;
  for(const name of Object.keys(actions)){if(name==='idle')continue;const wanted=active&&name===activeMotion?1:0;gestureWeights[name]=(gestureWeights[name]||0)+(wanted-(gestureWeights[name]||0))*blend;gestureWeight+=gestureWeights[name]}
  gestureWeight=Math.min(1,gestureWeight);
  if((liveAudioLevel!==null||['audio','viseme'].includes(targetState.mouth.mode))&&desired.jawOpen>.04)lastSpeechTime=time;
  const speaking=time-lastSpeechTime<.18;
  talkWeight+=((idle&&speaking?1:0)-talkWeight)*(1-Math.exp(-dt*4));
  for(const action of Object.values(actions))action.setEffectiveWeight(0);
  actions.idle.timeScale=idle?1:0;if(!idle)actions.idle.time=0;
  actions.idle.setEffectiveWeight((1-gestureWeight)*(1-talkWeight));
  actions.talk.setEffectiveWeight((1-gestureWeight)*talkWeight);
  for(const [name,weight]of Object.entries(gestureWeights))actions[name].setEffectiveWeight(actions[name].getEffectiveWeight()+weight);
  mixer.update(dt);
  const actual=active?activeMotion:talkWeight>.2?'talk':'idle';document.body.dataset.motion=actual;
  if(actual!==lastShownMotion){lastShownMotion=actual;document.dispatchEvent(new CustomEvent('avatar-motion',{detail:actual}))}
  const look=targetState.look;worldHeadRotation(look.yaw+(idle?.025*Math.sin(time*.7):0),look.pitch+(idle?.012*Math.sin(time*.9):0),look.roll+(idle?.015*Math.sin(time*.5):0));
 }
 renderer.render(scene,camera);
 requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
async function setState(patch){const r=await fetch('/api/state',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(patch)});const body=await r.json();if(!r.ok)throw new Error(body.error);return body}
window.avatar={ready,setState,setLiveAudioLevel:value=>{liveAudioLevel=value===null?null:Math.max(0,Math.min(1,value))},setExpression:(expression,intensity=1)=>setState({expression,intensity,controls:{},mouth:{mode:'expression'}}),setMouthOpen:open=>setState({mouth:{mode:'manual',open}}),setViseme:(viseme,weight=1)=>setState({mouth:{mode:'viseme',viseme,weight}}),setAudioLevel:level=>setState({mouth:{mode:'audio',level}}),setLook:look=>setState({look}),playMotion:(name,options={})=>setState({motion:{name,...options}}),reset:()=>fetch('/api/reset',{method:'POST'}).then(r=>r.json()),setFraming:value=>{framing=value;frame()},getState:()=>structuredClone(targetState),getDiagnostics:()=>({loaded:!!model,motion:document.body.dataset.motion,clips:Object.keys(actions),morphControls:[...bindings.keys()],weights:{...weights},meshes:renderer.info.render.calls,triangles:renderer.info.render.triangles,head:!!head,frame:renderer.info.render.frame}),captureStream:(fps=30)=>renderer.domElement.captureStream(fps)};
