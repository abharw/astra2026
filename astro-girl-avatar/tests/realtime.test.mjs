import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRealtimeCall,sessionConfig} from '../realtime-server.mjs';
const manifest=JSON.parse(fs.readFileSync(new URL('../assets/character.json',import.meta.url)));
test('Realtime SDP proxy keeps the credential server-side and includes valid avatar tools',async()=>{
 const answer=await createRealtimeCall('v=0\r\nm=audio',manifest,{key:'test-secret',fetcher:async(url,options)=>{
  assert.equal(url,'https://api.openai.com/v1/realtime/calls');assert.equal(options.headers.Authorization,'Bearer test-secret');
  assert.equal(options.body.get('sdp'),'v=0\r\nm=audio');const config=JSON.parse(options.body.get('session'));
  assert.equal(config.type,'realtime');assert.equal(config.audio.output.voice,'marin');assert.deepEqual(config.tools[0].parameters.properties.motion.enum,Object.keys(manifest.motions));return new Response('v=0\r\nanswer',{status:201});
 }});assert.equal(answer,'v=0\r\nanswer');
});
test('Realtime rejects missing credentials and malformed offers before fetching',async()=>{
 let fetched=false;const fetcher=async()=>{fetched=true;throw new Error('unexpected')};
 await assert.rejects(createRealtimeCall('v=0',manifest,{key:'',fetcher}),/API key/);
 await assert.rejects(createRealtimeCall('{}',manifest,{key:'test',fetcher}),/Invalid WebRTC/);
 assert.equal(fetched,false);
});
test('Realtime errors never return upstream credential text',async()=>{
 await assert.rejects(createRealtimeCall('v=0',manifest,{key:'test-secret',fetcher:async()=>new Response(JSON.stringify({error:{message:'invalid test-secret'}}),{status:401})}),e=>e.status===401&&!e.message.includes('test-secret'));
 await assert.rejects(createRealtimeCall('v=0',manifest,{key:'test-secret',fetcher:async()=>new Response(JSON.stringify({error:{message:'failure test-secret sk-anothercredential'}}),{status:400})}),e=>!e.message.includes('test-secret')&&!e.message.includes('sk-'));
});
