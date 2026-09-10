// Count completed spoken exchanges, not transcript fragments or tool continuations.
export function completedBackgroundTurn(response,userText=''){
 if(response.status!=='completed'||response.output?.some(item=>item.type==='function_call'))return null;
 const spoken=(response.output||[]).filter(item=>item.type==='message').flatMap(item=>item.content||[]).map(part=>part.transcript||part.text||'').join(' ').trim();
 if(!spoken)return null;
 return {context:[userText&&'User: '+userText,'Astra: '+spoken].filter(Boolean).join('\n').slice(-4000),turnId:response.id};
}
export function createBackgroundTurnTracker(onTurn){
 const pending=new Map(),finished=new Set(),settled=new Set();
 const remember=(set,id)=>{set.add(id);if(set.size>100)set.delete(set.values().next().value)};
 function flush(id){if(!pending.has(id)||!finished.has(id)||settled.has(id))return;const turn=pending.get(id);pending.delete(id);finished.delete(id);remember(settled,id);onTurn(turn)}
 return {
  complete(response,userText,{skip=false}={}){if(settled.has(response.id))return;if(skip){this.cancel(response.id);return}const turn=completedBackgroundTurn(response,userText);if(!turn)return;pending.set(response.id,turn);const audio=response.output.some(item=>item.content?.some(part=>part.type==='audio'));if(!audio)remember(finished,response.id);flush(response.id)},
  playbackFinished(id){remember(finished,id);flush(id)},
  cancel(id){pending.delete(id);finished.delete(id);remember(settled,id)}
 };
}

// The live studio counts recognized user input, independently of reply playback.
export function createUserBackgroundTurnTracker(onTurn){
 const seen=new Set();
 function remember(id){seen.add(id);if(seen.size>100)seen.delete(seen.values().next().value)}
 return {
  userTurn(id,text){if(!id||seen.has(id)||typeof text!=='string'||!text.trim())return;remember(id);onTurn({turnId:id,context:('User: '+text.trim()).slice(-4000)})},
  explicit(id){if(id)remember(id)}
 };
}
