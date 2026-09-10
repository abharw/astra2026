export const DEFAULT_STATE = Object.freeze({expression:'neutral',intensity:1,mouth:{mode:'expression',open:0,level:0,viseme:'rest',weight:1},look:{yaw:0,pitch:0,roll:0},blink:'auto',idle:true,motion:{name:'idle',speed:1,loop:true,sequence:0,startedAt:0},controls:{}});
export const cloneDefault=()=>structuredClone(DEFAULT_STATE);
const clamp=(v,lo=0,hi=1)=>Math.max(lo,Math.min(hi,v));
function number(v,name,lo=0,hi=1){if(typeof v!=='number'||!Number.isFinite(v))throw new Error(`${name} must be a finite number`);return clamp(v,lo,hi)}
function object(v,name){if(!v||Array.isArray(v)||typeof v!=='object')throw new Error(`${name} must be an object`)}
function keys(v,allowed,name){for(const k of Object.keys(v))if(!allowed.includes(k))throw new Error(`Unknown ${name} field: ${k}`)}
export function mergeState(current,patch,manifest){
 object(patch,'state');keys(patch,Object.keys(DEFAULT_STATE),'state');const next=structuredClone(current);
 if('expression'in patch){if(!(Object.hasOwn(manifest.expressions,patch.expression)))throw new Error('Unknown expression');next.expression=patch.expression}
 if('intensity'in patch)next.intensity=number(patch.intensity,'intensity');
 if('blink'in patch){if(!['auto','open','closed'].includes(patch.blink))throw new Error('blink must be auto, open or closed');next.blink=patch.blink}
 if('idle'in patch){if(typeof patch.idle!=='boolean')throw new Error('idle must be boolean');next.idle=patch.idle}
 if('look'in patch){object(patch.look,'look');keys(patch.look,['yaw','pitch','roll'],'look');for(const k of Object.keys(patch.look))next.look[k]=number(patch.look[k],k,-.6,.6)}
 if('mouth'in patch){object(patch.mouth,'mouth');keys(patch.mouth,['mode','open','level','viseme','weight'],'mouth');const m=patch.mouth;
  if('mode'in m){if(!['expression','manual','audio','viseme'].includes(m.mode))throw new Error('Unknown mouth mode');next.mouth.mode=m.mode}
  if('viseme'in m){if(!(Object.hasOwn(manifest.visemes,m.viseme)))throw new Error('Unknown viseme');next.mouth.viseme=m.viseme}
  for(const k of ['open','level','weight'])if(k in m)next.mouth[k]=number(m[k],k);
 }
 if('motion'in patch){
  object(patch.motion,'motion');keys(patch.motion,['name','speed','loop'],'motion');const m=patch.motion;
  const name=m.name??next.motion.name;if(!Object.hasOwn(manifest.motions,name))throw new Error('Unknown motion');
  const speed='speed'in m?number(m.speed,'motion speed',.25,2):1;
  if('loop'in m&&typeof m.loop!=='boolean')throw new Error('motion loop must be boolean');
  next.motion={name,speed,loop:m.loop??manifest.motions[name].loop,sequence:current.motion.sequence+1,startedAt:Date.now()};
 }
 if('controls'in patch){object(patch.controls,'controls');keys(patch.controls,manifest.controls,'control');next.controls={};for(const [k,v]of Object.entries(patch.controls))next.controls[k]=number(v,k)}
 return next;
}
export function composeWeights(state,manifest,autoBlink=0,liveAudioLevel=null){
 const out=Object.fromEntries(manifest.controls.map(k=>[k,0]));for(const [k,v]of Object.entries(manifest.expressions[state.expression]))out[k]=v*state.intensity;
 const m=liveAudioLevel===null?state.mouth:{...state.mouth,mode:'audio',level:liveAudioLevel};
 if(m.mode==='manual')out.jawOpen=m.open;
 if(m.mode==='audio')out.jawOpen=m.level;
 if(m.mode==='viseme'){
  for(const k of ['jawOpen','mouthPucker','mouthWide','mouthClose'])out[k]=0;
  for(const [k,v]of Object.entries(manifest.visemes[m.viseme]))out[k]=v*m.weight;
 }
 Object.assign(out,state.controls);
 out.jawOpen*=1-out.mouthClose;
 const blink=state.blink==='closed'?1:state.blink==='auto'?autoBlink:0;
 for(const side of ['Left','Right']){const key='eyeBlink'+side;out[key]=Math.max(out[key],blink);out['eyeWide'+side]*=1-out[key]}
 for(const k of manifest.controls)out[k]=clamp(out[k]);return out;
}
