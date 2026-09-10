import {avatarEvents} from './events.js';
const $=id=>document.getElementById(id);
let state=null;
export async function backgroundRequest(context,{force=false,turnId}={}){
 const r=await fetch('/api/background/context',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({context,force,turnId})});
 const value=await r.json();if(!r.ok)throw new Error(value.error);return value;
}
async function configure(patch){const r=await fetch('/api/background',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(patch)});const value=await r.json();if(!r.ok)throw new Error(value.error);return value}
avatarEvents.addEventListener('background',e=>{
 state=JSON.parse(e.data);document.dispatchEvent(new CustomEvent('avatar-background',{detail:state}));
 if(!$('background-status'))return;
 $('background-auto').checked=state.enabled;
 $('background-status').textContent=state.status==='generating'?'Creating scene':state.status==='queued'?'Scene queued':state.title;
 $('background-description').textContent=state.error||(['generating','queued'].includes(state.status)?'Astra can keep speaking while the next background is made.':state.enabled?`Next automatic scene in ${state.turnInterval-state.turnsSinceChange} turn${state.turnInterval-state.turnsSinceChange===1?'':'s'}. Ask for a background to change it sooner.`:'Automatic changes are paused. You can request a scene below.');
 $('background-description').dataset.error=String(!!state.error);
});
if($('background-auto')){
 const error=e=>{$('background-description').textContent=e.message;$('background-description').dataset.error='true'};
 $('background-auto').onchange=e=>configure({enabled:e.target.checked}).catch(error);
 $('background-reset').onclick=()=>configure({reset:true}).catch(error);
 $('background-form').onsubmit=e=>{e.preventDefault();const context=$('background-prompt').value.trim();if(context)backgroundRequest(context,{force:true}).catch(error)};
}
