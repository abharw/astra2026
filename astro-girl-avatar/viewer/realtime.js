import {backgroundRequest} from './backgrounds.js';
import {connectAudioStream} from './voice-adapter.js';
import {gateMicrophone,turnDetection,MICROPHONE_CONSTRAINTS} from './voice-input.js';
const $=id=>document.getElementById(id);
let session=null;
const status=text=>{$('realtime-status').textContent=text};
const showError=e=>{$('realtime-error').textContent=e.message||String(e)};
function enabled(ready){
 $('realtime-connect').disabled=!!session;$('realtime-disconnect').disabled=!session;
 for(const id of ['realtime-send','realtime-stop','realtime-mic'])$(id).disabled=!ready;
}
function send(event,s=session){if(!s||s.dc?.readyState!=='open')throw new Error('Connect Realtime first.');s.dc.send(JSON.stringify(event))}
function updateMicrophone(s=session){
 const mode=$('realtime-input-mode').value,push=mode==='push';$('realtime-hold').hidden=!push;
 $('realtime-hold').disabled=!s?.mic;$('realtime-hold').setAttribute('aria-pressed',String(!!s?.holding));
 if(!s)return;
 const busy=!!(s.waiting||s.generating||s.playing||s.toolPending||s.cooldown);
 gateMicrophone(s.mic,{mode,holding:s.holding,busy});
 if(s.mic)$('realtime-mic-note').textContent=mode==='auto'?'Listening — you can speak to interrupt Astra.':busy?'Microphone paused while Astra replies. Use Stop reply to interrupt.':push?'Hold the button while speaking, then release to send.':'Listening for your voice. Background noise is filtered.';
}
function settleReply(s){
 if(session!==s||s.holding)return;s.waiting=false;s.generating=false;s.toolPending=false;s.cooldown=true;clearTimeout(s.resumeTimer);updateMicrophone(s);
 s.resumeTimer=setTimeout(()=>{if(session!==s)return;s.cooldown=false;if($('realtime-input-mode').value!=='auto')send({type:'input_audio_buffer.clear'},s);updateMicrophone(s)},220);
}
async function publishLevel(level,s){
 if(session!==s)return;window.avatar.setLiveAudioLevel(level);s.pendingLevel=level;if(s.publishing)return;s.publishing=true;
 try{while(session===s&&s.pendingLevel!==null){const value=s.pendingLevel;s.pendingLevel=null;s.inflight=window.avatar.setAudioLevel(value);await s.inflight}}catch(e){showError(e)}finally{s.publishing=false}
}
async function disconnect(){
 const s=session;if(!s)return;session=null;s.abort.abort();clearTimeout(s.timeout);clearTimeout(s.resumeTimer);s.pendingLevel=null;
 s.mic?.getTracks().forEach(t=>t.stop());s.audio?.pause();if(s.audio)s.audio.srcObject=null;s.dc?.close();s.pc?.close();
 if(s.adapter)await s.adapter.dispose();else await s.context?.close();
 // Wait for any previous level POST before sending the final zero.
 if(s.inflight)await s.inflight.catch(()=>{});
 await window.avatar.setState({mouth:{mode:'audio',level:0},motion:{name:'idle'}});window.avatar.setLiveAudioLevel(null);
 $('realtime-mic').textContent='Enable microphone';$('realtime-mic').setAttribute('aria-pressed','false');$('realtime-mic-note').textContent='Microphone is off. You can send text and hear a reply.';
 $('realtime-section').dataset.speaking='false';enabled(false);updateMicrophone();status('Offline');
}
async function toolCall(item,s){
 try{
  if(item.name!=='set_avatar')throw new Error('Unsupported avatar tool.');
  const args=JSON.parse(item.arguments);const patch={};
  for(const k of Object.keys(args))if(!['expression','motion','intensity'].includes(k))throw new Error('Unsupported avatar setting.');
  if(args.expression!==undefined)patch.expression=args.expression;
  if(args.intensity!==undefined)patch.intensity=args.intensity;
  if(args.motion!==undefined)patch.motion={name:args.motion};
  await window.avatar.setState(patch);
  send({type:'conversation.item.create',item:{type:'function_call_output',call_id:item.call_id,output:JSON.stringify({ok:true,...args})}},s);
 }catch(e){send({type:'conversation.item.create',item:{type:'function_call_output',call_id:item.call_id,output:JSON.stringify({ok:false,error:e.message})}},s)}
}
async function handle(event,s){
 if(session!==s)return;
 if(event.response_id&&s.cancelledResponses.has(event.response_id))return;
 switch(event.type){
  case 'session.created': status('Connected');break;
  case 'response.created':s.responseId=event.response.id;s.cancelled=false;s.waiting=true;s.generating=true;updateMicrophone(s);s.transcript='';$('realtime-transcript').textContent='';status('Thinking');break;
  case 'response.output_audio_transcript.delta':s.transcript+=event.delta;$('realtime-transcript').textContent=s.transcript;break;
  case 'response.output_audio_transcript.done':$('realtime-transcript').textContent=event.transcript;{const context=[s.userText&&'User: '+s.userText,'Astra: '+event.transcript].filter(Boolean).join('\n').slice(-4000);backgroundRequest(context).catch(error=>{const note=$('background-description');if(note)note.textContent=error.message})}break;
  case 'conversation.item.input_audio_transcription.completed':s.userText=event.transcript;$('realtime-mic-note').textContent='You: '+event.transcript;break;
  case 'input_audio_buffer.speech_started':if(!s.generating&&!s.playing)status('Listening');break;
  case 'input_audio_buffer.speech_stopped':s.waiting=true;updateMicrophone(s);status('Thinking');break;
  case 'output_audio_buffer.started':s.playbackId=event.response_id;s.playing=true;updateMicrophone(s);$('realtime-section').dataset.speaking='true';status('Speaking');break;
  case 'output_audio_buffer.stopped':
  case 'output_audio_buffer.cleared':if(s.playbackId&&event.response_id&&event.response_id!==s.playbackId)break;s.playbackFinished=event.response_id;s.playing=false;$('realtime-section').dataset.speaking='false';if(!s.toolPending&&!s.generating)settleReply(s);status('Connected');break;
  case 'response.done':{
   const response=event.response;if(s.cancelledResponses.has(response.id))break;if(s.responseId&&response.id!==s.responseId)break;s.generating=false;
   if(response.status==='cancelled'||s.cancelled){if(!s.playing)settleReply(s);status('Connected');break}
   if(response.status==='failed'){showError(new Error(response.status_details?.error?.message||'The voice response failed.'));settleReply(s);status('Connected');break}
   const calls=(response.output||[]).filter(item=>item.type==='function_call');
   s.toolPending=!!calls.length;updateMicrophone(s);
   for(const call of calls){if(session!==s)return;await toolCall(call,s)}
   if(calls.length&&session===s&&!s.cancelled){s.waiting=true;s.toolPending=false;send({type:'response.create',response:{tool_choice:'none'}},s)}
   else if(!s.playing){const hasAudio=(response.output||[]).some(item=>item.content?.some(part=>part.type==='audio'));if(!hasAudio||s.playbackFinished===response.id)settleReply(s);status('Connected')}break;
  }
  case 'error':showError(new Error(event.error?.message||'Realtime error'));break;
 }
}
async function connect(){
 if(session)return;$('realtime-error').textContent='';
 const s={pc:new RTCPeerConnection(),context:new AudioContext(),audio:new Audio(),abort:new AbortController(),mic:null,adapter:null,generating:false,playing:false,transcript:'',pendingLevel:null,publishing:false,waiting:false,holding:false,cooldown:false,toolPending:false,cancelledResponses:new Set()};session=s;enabled(false);status('Connecting');
 try{
  await s.context.resume();
  document.dispatchEvent(new Event('avatar-realtime-start'));$('voice-audio').pause();
  s.transceiver=s.pc.addTransceiver('audio',{direction:'sendrecv'});
  s.pc.ontrack=async event=>{
   if(session!==s||event.track.kind!=='audio')return;
   try{
    const stream=event.streams[0]||new MediaStream([event.track]);
    // Attach remote media to a playback element so WebKit starts decoding it.
    // Only the element is audible; the analyser's output is muted.
    s.audio.autoplay=true;s.audio.srcObject=stream;await s.audio.play();
    s.adapter=await connectAudioStream(stream,{context:s.context,monitor:false,onLevel:level=>{$('realtime-level').value=level;s.levelPromise=publishLevel(level,s)}});
    if(session!==s)await s.adapter.dispose();
   }catch(e){showError(e)}
  };
  s.pc.onconnectionstatechange=()=>{if(session===s&&['failed','closed'].includes(s.pc.connectionState)){showError(new Error('Realtime connection closed. Connect again to continue.'));disconnect().catch(showError)}};
  s.dc=s.pc.createDataChannel('oai-events');
  s.dc.onmessage=e=>{try{handle(JSON.parse(e.data),s).catch(showError)}catch(error){showError(error)}};
  const opened=new Promise((resolve,reject)=>{
   s.timeout=setTimeout(()=>reject(new Error('Realtime connection timed out.')),30000);
   s.dc.onopen=()=>{clearTimeout(s.timeout);resolve()};s.dc.onerror=()=>reject(new Error('Realtime data connection failed.'));
   s.abort.signal.addEventListener('abort',()=>reject(new DOMException('Disconnected','AbortError')),{once:true});
  });
  // Attach immediately so cancellation during the SDP request cannot cause an unhandled rejection.
  opened.catch(()=>{});
  const offer=await s.pc.createOffer();await s.pc.setLocalDescription(offer);
  const response=await fetch('/api/realtime/session',{method:'POST',headers:{'Content-Type':'application/sdp'},body:offer.sdp,signal:s.abort.signal});
  if(!response.ok){const data=await response.json();throw new Error(data.error||'Unable to connect Realtime.')}
  await s.pc.setRemoteDescription({type:'answer',sdp:await response.text()});await opened;
  if(session!==s)return;
  await window.avatar.setState({mouth:{mode:'audio',level:0},motion:{name:'idle'}});send({type:'session.update',session:{type:'realtime',audio:{input:{turn_detection:turnDetection($('realtime-input-mode').value)}}}},s);enabled(true);updateMicrophone(s);status('Connected');
 }catch(e){if(e.name!=='AbortError')showError(e);if(session===s)await disconnect()}
}
async function toggleMicrophone(){
 const s=session;if(!s)return;
 if(s.mic){await s.transceiver.sender.replaceTrack(null);s.mic.getTracks().forEach(t=>t.stop());s.mic=null;s.holding=false;send({type:'input_audio_buffer.clear'},s);updateMicrophone(s);$('realtime-mic').textContent='Enable microphone';$('realtime-mic').setAttribute('aria-pressed','false');$('realtime-mic-note').textContent='Microphone is off. You can send text and hear a reply.';return}
 const stream=await navigator.mediaDevices.getUserMedia({audio:{...MICROPHONE_CONSTRAINTS}});
 if(session!==s){stream.getTracks().forEach(t=>t.stop());return}
 try{gateMicrophone(stream,{mode:$('realtime-input-mode').value,holding:false,busy:s.waiting||s.generating||s.playing});await s.transceiver.sender.replaceTrack(stream.getAudioTracks()[0]);s.mic=stream}catch(e){stream.getTracks().forEach(t=>t.stop());throw e}
 $('realtime-mic').textContent='Turn microphone off';$('realtime-mic').setAttribute('aria-pressed','true');updateMicrophone(s);
}
function stopReply(){
 const s=session;if(!s)return;if(s.responseId)s.cancelledResponses.add(s.responseId);if(s.playbackId)s.cancelledResponses.add(s.playbackId);if(s.generating)send({type:'response.cancel'});if(s.playing)send({type:'output_audio_buffer.clear'});
 s.cancelled=true;s.generating=false;s.playing=false;settleReply(s);$('realtime-section').dataset.speaking='false';status('Connected');
}
$('realtime-connect').onclick=()=>connect().catch(showError);
$('realtime-disconnect').onclick=()=>disconnect().catch(showError);
$('realtime-mic').onclick=()=>toggleMicrophone().catch(showError);
$('realtime-stop').onclick=()=>{try{stopReply()}catch(e){showError(e)}};
$('realtime-form').onsubmit=async event=>{
 event.preventDefault();const text=$('realtime-prompt').value.trim();if(!text)return;if(session)session.userText=text;
 try{if(session.generating||session.playing)stopReply();await session.context.resume();session.waiting=true;session.cancelled=false;updateMicrophone(session);send({type:'conversation.item.create',item:{type:'message',role:'user',content:[{type:'input_text',text}]}});send({type:'response.create'});$('realtime-prompt').value='';$('realtime-error').textContent=''}catch(e){showError(e)}
};
$('realtime-input-mode').onchange=()=>{
 const s=session;if(s){s.holding=false;send({type:'session.update',session:{type:'realtime',audio:{input:{turn_detection:turnDetection($('realtime-input-mode').value)}}}});send({type:'input_audio_buffer.clear'})}updateMicrophone(s);
};
function startHold(){
 const s=session;if(!s?.mic||s.holding)return;
 if(s.waiting||s.generating||s.playing)stopReply();clearTimeout(s.resumeTimer);s.cooldown=false;s.waiting=false;s.generating=false;s.playing=false;
 send({type:'input_audio_buffer.clear'},s);s.holding=true;s.holdStarted=performance.now();updateMicrophone(s);status('Listening');
}
function endHold(){
 const s=session;if(!s?.holding)return;s.holding=false;updateMicrophone(s);
 if(performance.now()-s.holdStarted<180){send({type:'input_audio_buffer.clear'});status('Connected');return}
 s.waiting=true;s.cancelled=false;updateMicrophone(s);send({type:'input_audio_buffer.commit'});send({type:'response.create'});status('Thinking');
}
$('realtime-hold').onpointerdown=e=>{e.preventDefault();e.currentTarget.setPointerCapture(e.pointerId);startHold()};
$('realtime-hold').onpointerup=endHold;$('realtime-hold').onpointercancel=endHold;
$('realtime-hold').onkeydown=e=>{if([' ','Enter'].includes(e.key)&&!e.repeat){e.preventDefault();startHold()}};
$('realtime-hold').onkeyup=e=>{if([' ','Enter'].includes(e.key)){e.preventDefault();endHold()}};
$('realtime-hold').onblur=endHold;
window.addEventListener('pagehide',()=>{const s=session;s?.mic?.getTracks().forEach(t=>t.stop());s?.pc.close();s?.abort.abort()});
fetch('/api/realtime/status').then(r=>r.json()).then(value=>{$('realtime-info').textContent=value.configured?`${value.model} · Marin voice. Expressions and mouth movement follow the live reply.`:'Set an OpenAI API key on the local server to enable Realtime voice.'}).catch(showError);
