import test from 'node:test';import assert from 'node:assert/strict';import {once} from 'node:events';import {WebSocket} from 'ws';
import {startBridge} from '../bridge.mjs';
const assembly=()=>({name:'Box',description:'Test assembly',confidence:'low',bounds:[.2,.2,.8,.8],sizeMeters:[1,1,1],parts:[{id:'shell',name:'Shell',description:'Body',function:'Holds parts',uncertainty:'Approximate',sourceIds:[],evidence:'observed',explode:[0,0,.3],primitives:[{kind:'box',position:[0,0,0],size:[1,1,1],rotation:[0,0,0],color:[.4,.4,.4],vertices:[],triangles:[]}]}]});
const message=text=>({output:[{type:'message',content:[{type:'output_text',text:JSON.stringify(text)}]}]});
async function fixture(t,api){const bridge=startBridge({key:'test-only',token:'test-token-0123456789012345',port:0,request:api});await once(bridge.server,'listening');const socket=new WebSocket(`ws://127.0.0.1:${bridge.server.address().port}/session`,{headers:{Authorization:'Bearer test-token-0123456789012345'}});t.after(()=>{socket.terminate();bridge.close();});const queue=[];socket.on('message',raw=>queue.push(JSON.parse(raw)));await once(socket,'open');return {socket,queue,send:e=>socket.send(JSON.stringify(e)),wait:async(type,id)=>{const until=Date.now()+3000;while(Date.now()<until){const e=queue.find(e=>e.type===type&&(!id||e.request_id===id));if(e)return e;await new Promise(r=>setTimeout(r,5));}throw Error('Timed out '+type);}};}
const normal=async body=>body.text.format.name==='object_identity'?message({label:'Box',brand:'',model:'',identifiersVisible:false,visibleEvidence:'',query:'box manual',uncertainty:'Unknown model'}):body.text.format.name==='object_references'?{...message({summary:'No reference',gaps:[],sources:[]}),output:[{type:'web_search_call',action:{sources:[]} },...message({summary:'No reference',gaps:[],sources:[]}).output]}:message(assembly());
test('research pipeline completes and rebuild keeps object identity with a new revision',async t=>{const f=await fixture(t,normal);f.send({type:'reconstruct',request_id:'first',object_id:'object-A',image:'data:image/jpeg;base64,AA==',target:[.5,.5]});const first=await f.wait('reconstruction.complete','first');assert.equal(first.assembly.revision,1);assert.equal(first.assembly.research.searchPerformed,true);f.send({type:'rebuild',request_id:'revision',object_id:'object-A',hint:'Improve shell'});const revised=await f.wait('reconstruction.complete','revision');assert.equal(revised.mode,'refine');assert.equal(revised.object_id,'object-A');assert.equal(revised.assembly.revision,2);});
test('cancellation during search cannot install a late generated model',async t=>{let entered=false;const f=await fixture(t,async(body,signal)=>{if(body.text.format.name==='object_identity')return normal(body);entered=true;await new Promise(r=>setTimeout(r,60));return normal(body);});f.send({type:'reconstruct',request_id:'cancelled',image:'data:image/jpeg;base64,AA=='});while(!entered)await new Promise(r=>setTimeout(r,5));f.send({type:'reconstruction.cancel'});await f.wait('reconstruction.error','cancelled');assert.equal(f.queue.some(e=>e.type==='reconstruction.complete'),false);});
test('failed search is explicit and never invents reference evidence',async t=>{const f=await fixture(t,async body=>{if(body.text.format.name==='object_references')throw Error('Search denied');return normal(body);});f.send({type:'reconstruct',request_id:'no-search',image:'data:image/jpeg;base64,AA=='});const result=await f.wait('reconstruction.complete','no-search');assert.equal(result.assembly.research.status,'search_failed');assert.deepEqual(result.assembly.research.sources,[]);assert.ok(f.queue.some(e=>e.type==='research.warning'));});
test('restored scenes explain parts without regenerating geometry',async t=>{const f=await fixture(t,()=>{throw Error('No API call should occur');});const a=assembly();a.research={sources:[{id:'S1',title:'Manual',url:'https://example.com',match:'similar'}]};a.parts[0].sourceIds=['S1'];f.send({type:'scene.update',object_id:'saved-object',assembly:a});f.send({type:'part.explain',part:'shell'});const explained=await f.wait('part.explanation');assert.equal(explained.part.function,'Holds parts');assert.equal(explained.sources[0].id,'S1');});

test('refinement freezes source assembly while selection changes during research',async t=>{
 let pause=false, entered=false, resume, captured;
 const f=await fixture(t,async body=>{
  if(pause&&body.text.format.name==='object_references'){entered=true;await new Promise(r=>resume=r);}
  if(pause&&body.text.format.name==='ar_assembly')captured=JSON.parse(body.input[0].content[0].text).previousAssembly;
  return normal(body);
 });
 f.send({type:'reconstruct',request_id:'seed',object_id:'original',image:'data:image/jpeg;base64,AA=='});
 await f.wait('reconstruction.complete','seed');pause=true;
 f.send({type:'rebuild',request_id:'refine-frozen',object_id:'original'});
 while(!entered)await new Promise(r=>setTimeout(r,5));
 const other=assembly();other.name='Different object';other.revision=20;
 f.send({type:'scene.update',object_id:'different',assembly:other});
 f.send({type:'ping'});await f.wait('pong');resume();
 const result=await f.wait('reconstruction.complete','refine-frozen');
 assert.equal(captured.name,'Box');assert.equal(result.assembly.revision,2);assert.equal(result.object_id,'original');
});


test('cancel acknowledges immediately and a new request is not blocked by late work',async t=>{
 let release, entered=false, first=true;
 const f=await fixture(t,async body=>{
  if(body.text.format.name==='ar_assembly'&&first){first=false;entered=true;await new Promise(r=>release=r);}
  return normal(body);
 });
 f.send({type:'reconstruct',request_id:'old',image:'data:image/jpeg;base64,AA=='});
 while(!entered)await new Promise(r=>setTimeout(r,5));
 f.send({type:'reconstruction.cancel'});await f.wait('reconstruction.cancelled');
 f.send({type:'reconstruct',request_id:'new',image:'data:image/jpeg;base64,AA=='});
 await f.wait('reconstruction.complete','new');release();await f.wait('reconstruction.error','old');
 assert.equal(f.queue.some(e=>e.type==='reconstruction.complete'&&e.request_id==='old'),false);
});
