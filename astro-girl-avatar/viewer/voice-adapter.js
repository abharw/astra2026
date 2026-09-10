/** Drive outgoing audio playback, supplied by your voice API. */
function meter(context,source,{onLevel,onEnd,playing=()=>true,monitor=true}={}){
 const analyser=context.createAnalyser();analyser.fftSize=1024;source.connect(analyser);
 const gain=context.createGain();gain.gain.value=monitor?1:0;analyser.connect(gain);gain.connect(context.destination);
 const samples=new Float32Array(analyser.fftSize);let last=-1,disposed=false;
 const emit=(value,rms=0)=>{if(Math.abs(value-last)>.008||(value===0&&last!==0)){last=value;onLevel?.(value,rms)}};
 const timer=setInterval(()=>{analyser.getFloatTimeDomainData(samples);let sum=0;for(const x of samples)sum+=x*x;const rms=Math.sqrt(sum/samples.length);emit(playing()?Math.min(1,Math.max(0,(rms-.012)*5)):0,rms)},40);
 return {context,analyser,resume:()=>context.resume(),end:()=>{emit(0);onEnd?.()},dispose:async()=>{if(disposed)return;disposed=true;clearInterval(timer);source.disconnect();analyser.disconnect();gain.disconnect();await context.close();emit(0)}};
}
export async function connectAudioElement(audio,options={}){
 const context=new AudioContext();const source=context.createMediaElementSource(audio);
 const adapter=meter(context,source,{...options,playing:()=>!audio.paused&&!audio.ended});await context.resume();
 const end=()=>adapter.end();audio.addEventListener('ended',end);audio.addEventListener('pause',end);
 const dispose=adapter.dispose;adapter.dispose=async()=>{audio.removeEventListener('ended',end);audio.removeEventListener('pause',end);await dispose()};return adapter;
}
/** Supply an existing WebRTC/voice stream. This does not request microphone access. */
export async function connectAudioStream(stream,options={}){
 const context=options.context??new AudioContext();const source=context.createMediaStreamSource(stream);const adapter=meter(context,source,{monitor:false,...options});await context.resume();return adapter;
}
/** Use timestamps relative to audio playback, not network arrival. */
export function scheduleVisemes(audio,events,onViseme){
 if(!Array.isArray(events)||events.some(e=>!Number.isFinite(e.timeMs)||e.timeMs<0||typeof e.viseme!=='string'||(e.weight!==undefined&&(!Number.isFinite(e.weight)||e.weight<0||e.weight>1))))throw new Error('Expected {timeMs, viseme, weight?} events');
 const sorted=events.toSorted((a,b)=>a.timeMs-b.timeMs);let index=-1,lastTime=-1,last='',raf,stopped=false;
 const emit=(v,w)=>{const signature=v+':'+w;if(signature!==last){last=signature;onViseme(v,w)}};
 const tick=()=>{if(stopped)return;const ms=audio.currentTime*1000;if(ms<lastTime)index=-1;lastTime=ms;
  if(audio.paused||audio.ended){emit('rest',1);index=-1}else{let next=index;while(next+1<sorted.length&&sorted[next+1].timeMs<=ms)next++;index=next;const e=sorted[index];emit(e?.viseme??'rest',e?.weight??1)}raf=requestAnimationFrame(tick)};
 raf=requestAnimationFrame(tick);return()=>{stopped=true;cancelAnimationFrame(raf);emit('rest',1)};
}
