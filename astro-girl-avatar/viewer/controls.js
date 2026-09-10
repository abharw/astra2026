import {connectAudioElement} from './voice-adapter.js';
import {composeWeights} from './state.js';
let characterManifest;
const $=id=>document.getElementById(id);let talking=false,timer,adapter,objectURL,audioRequest=false,pendingLevel=null;
const glyphs={neutral:'•‿•',happy:'^‿^',sad:'•︵•',angry:'>_<',surprised:'•o•',thinking:'•_•',wink:'–‿•',sleepy:'–_–'};
const title=s=>s[0].toUpperCase()+s.slice(1);
const act=fn=>Promise.resolve().then(fn).catch(e=>{$('error').textContent=e.message});
function stopTalk(){talking=false;clearInterval(timer);$('talk').textContent='Play silent talking demo'}
function sync(state){
 document.querySelectorAll('#expressions button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.name===state.expression)));
 document.querySelectorAll('#visemes button').forEach(b=>b.setAttribute('aria-pressed',String(state.mouth.mode==='viseme'&&b.dataset.name===state.mouth.viseme)));
 $('active-expression').textContent=title(state.expression);$('mouth-mode').textContent=title(state.mouth.mode);$('intensity').value=state.intensity;$('intensity-value').value=Math.round(state.intensity*100)+'%';
 $('jaw').value=characterManifest?composeWeights(state,characterManifest).jawOpen:0;$('jaw-value').value=Math.round(Number($('jaw').value)*100)+'%';$('idle').checked=state.idle;$('blink').checked=state.blink==='auto';$('yaw').value=state.look.yaw;$('pitch').value=state.look.pitch;
 $('connection').textContent='Connected locally';
}
window.avatar.ready.then(manifest=>{
 characterManifest=manifest;
 for(const name of Object.keys(manifest.expressions)){const b=document.createElement('button');b.dataset.name=name;b.setAttribute('aria-pressed','false');b.innerHTML=`<span aria-hidden="true">${glyphs[name]}</span>${title(name)}`;b.addEventListener('click',()=>act(()=>{stopTalk();return window.avatar.setExpression(name,Number($('intensity').value))}));$('expressions').append(b)}
 for(const name of Object.keys(manifest.visemes)){const b=document.createElement('button');b.textContent=name.toUpperCase();b.dataset.name=name;b.setAttribute('aria-pressed','false');b.addEventListener('click',()=>act(()=>{stopTalk();return window.avatar.setViseme(name)}));$('visemes').append(b)}
 for(const [name,meta]of Object.entries(manifest.motions)){const b=document.createElement('button');b.dataset.name=name;b.textContent=title(name.replaceAll('_',' '));b.title=meta.description;b.addEventListener('click',()=>act(()=>window.avatar.playMotion(name)));$('motions').append(b)}
 sync(window.avatar.getState());
});
document.addEventListener('avatar-realtime-start',stopTalk);
document.addEventListener('avatar-motion',e=>{$('active-motion').textContent=title(e.detail.replaceAll('_',' '));document.querySelectorAll('#motions button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.name===e.detail)))});
document.addEventListener('avatar-state',e=>sync(e.detail));document.addEventListener('avatar-disconnected',()=>{$('connection').textContent='Reconnecting…'});
$('reset').onclick=()=>act(()=>{stopTalk();$('voice-audio').pause();return window.avatar.reset()});
$('intensity').oninput=e=>act(()=>window.avatar.setState({intensity:Number(e.target.value)}));
$('jaw').oninput=e=>act(()=>{stopTalk();return window.avatar.setMouthOpen(Number(e.target.value))});
$('yaw').oninput=e=>act(()=>window.avatar.setLook({yaw:Number(e.target.value)}));$('pitch').oninput=e=>act(()=>window.avatar.setLook({pitch:Number(e.target.value)}));
$('idle').onchange=e=>act(()=>window.avatar.setState({idle:e.target.checked}));$('blink').onchange=e=>act(()=>window.avatar.setState({blink:e.target.checked?'auto':'open'}));
for(const id of ['full','portrait'])$(id).onclick=()=>{window.avatar.setFraming(id);for(const q of ['full','portrait']){$(q).classList.toggle('selected',q===id);$(q).setAttribute('aria-pressed',String(q===id))}};
$('talk').onclick=()=>act(async()=>{
 if(talking){stopTalk();await window.avatar.setState({mouth:{mode:'expression'}});return}
 $('voice-audio').pause();talking=true;$('talk').textContent='Stop talking demo';const sequence=['mbp','aa','ee','rest','ih','oh','ou','fv','aa','rest'];let index=0;
 await window.avatar.setViseme(sequence[index++]);timer=setInterval(()=>act(()=>window.avatar.setViseme(sequence[index++%sequence.length],.75+Math.sin(index)*.15)),180);
});
async function publishLevel(level){pendingLevel=level;if(audioRequest)return;audioRequest=true;try{while(pendingLevel!==null){const next=pendingLevel;pendingLevel=null;await window.avatar.setAudioLevel(next)}}catch(e){$('error').textContent=e.message}finally{audioRequest=false}}
$('audio-file').onchange=e=>act(async()=>{
 const file=e.target.files[0];if(!file)return;stopTalk();const old=$('voice-audio');old.pause();if(adapter)await adapter.dispose();if(objectURL)URL.revokeObjectURL(objectURL);
 // A fresh media element avoids creating two MediaElementSources for the same element.
 const audio=document.createElement('audio');audio.id='voice-audio';audio.controls=true;old.replaceWith(audio);objectURL=URL.createObjectURL(file);audio.src=objectURL;
 adapter=await connectAudioElement(audio,{onLevel:publishLevel,onEnd:()=>{$('audio-note').textContent='Playback finished. The mouth returns to rest.'}});audio.onplay=()=>adapter.resume();$('audio-note').textContent='Audio-reactive mouth movement · '+file.name;await audio.play();
});
if(matchMedia('(prefers-reduced-motion: reduce)').matches)act(()=>window.avatar.setState({idle:false}));
