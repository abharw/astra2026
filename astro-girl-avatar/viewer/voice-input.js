/** Shared input policy for the browser and server. */
export const AUTO_VAD=Object.freeze({type:'server_vad',threshold:.72,prefix_padding_ms:220,silence_duration_ms:350,create_response:true,interrupt_response:true});
export const MICROPHONE_CONSTRAINTS=Object.freeze({echoCancellation:true,noiseSuppression:true,autoGainControl:false,channelCount:1});
export function gateMicrophone(stream,{mode='auto',holding=false,busy=false}={}){
 const enabled=mode==='auto'||(!busy&&(mode==='protected'||holding));
 for(const track of stream?.getAudioTracks()||[])track.enabled=enabled;
 return enabled;
}

export function turnDetection(mode='auto'){return mode==='push'?null:{...AUTO_VAD,interrupt_response:mode!=='protected'}}
