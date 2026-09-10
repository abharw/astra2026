import fs from 'node:fs';
import {AUTO_VAD} from './viewer/voice-input.js';
import os from 'node:os';
import path from 'node:path';
export function loadAPIKey(){
 if(process.env.OPENAI_API_KEY)return process.env.OPENAI_API_KEY.trim();
 try{return fs.readFileSync(path.join(os.homedir(),'.config/astra-girl/openai-api-key'),'utf8').trim()}catch{return ''}
}
export function sessionConfig(manifest){
 return {
  type:'realtime',model:process.env.OPENAI_REALTIME_MODEL||'gpt-realtime-2.1',output_modalities:['audio'],max_output_tokens:700,reasoning:{effort:'minimal'},
  audio:{input:{turn_detection:{...AUTO_VAD},noise_reduction:{type:'far_field'},transcription:{model:'gpt-4o-mini-transcribe'}},output:{voice:'marin'}},
  instructions:'You are Astra, a friendly expressive robot girl avatar. Speak naturally and keep replies concise, usually one or two sentences. You are an AI character. Use set_avatar when the user requests an expression or gesture; use set_background when the user asks to place our conversation in an environment or change that environment; otherwise start speaking directly without a tool call. Keep ordinary greetings conversational and quick. Gestures run once and automatically return to idle. Do not repeatedly call tools for the same user turn. Facial expressions and gestures are separate from speech: the local renderer automatically synchronizes your mouth to the returned audio. Never claim you can see the user, access their files, or control FaceTime. The studio automatically chooses a fresh background after every three recognized user turns, even if the user interrupts your reply. A request to talk from or in a place is an explicit scene request even without the words background or change. Examples: "talk to me from a rainforest", "let us chat in a snowy cabin", "take me to Mars", or "imagine we are on a beach". Call set_background immediately with the requested environment. Resolve follow-up environmental directions such as "make it nighttime", "now outside", or "closer to the waterfall" against the most recently requested setting and send a complete updated scene description. Then speak naturally in that setting using appropriate surroundings, light, weather, or atmosphere; maintain the requested setting in follow-up conversation until it changes. Merely discussing a place, such as "tell me facts about Mars", is not an immediate scene request and stays on the ordinary three-turn cadence. The image is generated asynchronously; do not claim it is already displayed or that you visually inspected the generated image. Describe the intended setting without pretending to be physically there. Use set_avatar only for the character, never for scenery. Do not speak about tool internals unless asked.',
  tools:[{type:'function',name:'set_avatar',description:'Set the avatar facial expression and optionally perform a body gesture. Preserves speech mouth movement.',parameters:{type:'object',properties:{expression:{type:'string',enum:Object.keys(manifest.expressions)},motion:{type:'string',enum:Object.keys(manifest.motions)},intensity:{type:'number',minimum:0,maximum:1}},required:['expression'],additionalProperties:false}},{type:'function',name:'set_background',description:'Immediately place the conversation in a requested environment, including "talk to me from/in X", "take me to X", "imagine we are in X", or a change to the current setting such as "make it nighttime". No background keyword is required. Supply the complete setting for follow-up changes. Do not call merely for factual discussion of a place; ordinary conversation uses the three-turn cadence.',parameters:{type:'object',properties:{prompt:{type:'string',maxLength:1000}},required:['prompt'],additionalProperties:false}}],tool_choice:'auto'
 };
}
export async function createRealtimeCall(sdp,manifest,{key=loadAPIKey(),fetcher=fetch,signal}={}){
 if(!key)throw Object.assign(new Error('Add your OpenAI API key on the local server to connect.'),{status:503});
 if(typeof sdp!=='string'||!sdp.startsWith('v=0')||sdp.length>65536)throw Object.assign(new Error('Invalid WebRTC offer.'),{status:400});
 const body=new FormData();body.set('sdp',sdp);body.set('session',JSON.stringify(sessionConfig(manifest)));
 const response=await fetcher('https://api.openai.com/v1/realtime/calls',{method:'POST',headers:{Authorization:`Bearer ${key}`},body,signal:signal??AbortSignal.timeout(30000)});
 if(!response.ok){
  let data;try{data=await response.json()}catch{}
  const messages={401:'The OpenAI API key was rejected. Update the key on the local server.',403:'This API project does not have access to the requested Realtime model.',429:'OpenAI returned a quota or rate limit. Check this API project’s billing and limits.'};
  const message=messages[response.status]||String(data?.error?.message||'Could not establish the Realtime session.').replaceAll(key,'[redacted]').replace(/sk-[A-Za-z0-9_-]+/g,'[redacted]');
  throw Object.assign(new Error(message),{status:response.status});
 }
 return response.text();
}
