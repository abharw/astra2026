import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createBackgroundManager,generateBackground,BACKGROUND_MODELS} from '../background-server.mjs';
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function until(check){for(let i=0;i<100;i++){if(check())return;await wait(2)}assert.fail('State did not settle');}
const image=title=>({title,bytes:Buffer.alloc(128,1)});
async function fixture(t,generate){const directory=await fs.mkdtemp(path.join(os.tmpdir(),'astra-background-'));const manager=createBackgroundManager({directory,generate,delayMs:0,timeoutMs:1000});t.after(async()=>{manager.dispose();await fs.rm(directory,{recursive:true,force:true})});return {manager,directory};}

test('GPT-6 scene generation uses a server-side image tool and returns image bytes',async()=>{
 const key='test-private-value';let request;
 const result=await generateBackground({context:'Discussing the ocean',currentScene:'Studio'},{key,fetcher:async(url,options)=>{request={url,...options};return {ok:true,json:async()=>({output:[{type:'image_generation_call',result:Buffer.alloc(128,1).toString('base64')},{type:'message',content:[{type:'output_text',text:'Ocean reef'}]}]})}}});
 assert.equal(request.url,'https://api.openai.com/v1/responses');const body=JSON.parse(request.body);assert.equal(body.model,BACKGROUND_MODELS.director);assert.equal(body.tools[0].model,BACKGROUND_MODELS.image);assert.equal(body.store,false);assert.ok(!request.body.includes(key));assert.equal(result.title,'Ocean reef');assert.equal(result.bytes.length,128);
});
test('repeated or irrelevant conversation can keep the existing background without an image',async()=>{
 const result=await generateBackground({context:'Hello'},{key:'test',fetcher:async()=>({ok:true,json:async()=>({output:[{type:'message',content:[{type:'output_text',text:'KEEP'}]}]})})});assert.equal(result,null);
});
test('background errors redact upstream credentials',async()=>{
 const key='private-key-value';await assert.rejects(()=>generateBackground({context:'Ocean'},{key,fetcher:async()=>({ok:false,status:401,json:async()=>({error:{message:'Rejected '+key}})})}),e=>!e.message.includes(key)&&e.message.includes('[redacted]'));
});
test('a late image cannot replace a newer requested conversation scene',async t=>{
 let finishFirst;const calls=[];
 const {manager,directory}=await fixture(t,async input=>{calls.push(input.context);if(calls.length===1)return new Promise(r=>finishFirst=r);return image(input.context)});
 manager.request('Ocean');await until(()=>finishFirst);manager.request('Forest');manager.request('Moon');finishFirst(image('Ocean'));
 await until(()=>manager.get().status==='ready');assert.deepEqual(calls,['Ocean','Moon']);assert.equal(manager.get().title,'Moon');assert.equal((await fs.readdir(directory)).length,1);
});
test('turning automatic scenes off cancels pending updates and keeps the displayed image',async t=>{
 let resolveLate;const {manager}=await fixture(t,async input=>input.context==='first'?image('Ocean'):new Promise(r=>resolveLate=r));
 manager.request('first');await until(()=>manager.get().status==='ready');const url=manager.get().url;
 manager.request('late');await until(()=>resolveLate);manager.configure({enabled:false});resolveLate(image('Late'));await wait(10);
 assert.equal(manager.get().url,url);assert.equal(manager.get().status,'paused');manager.request('ignored');assert.equal(manager.get().status,'paused');
 manager.configure({reset:true});assert.equal(manager.get().url,null);
});
test('failed generation preserves the previous scene and exposes a retryable error',async t=>{
 const {manager}=await fixture(t,async input=>{if(input.context==='broken')throw new Error('Try again');return image('Ocean')});manager.request('ok');await until(()=>manager.get().status==='ready');const url=manager.get().url;
 manager.request('broken');await until(()=>manager.get().status==='error');assert.equal(manager.get().url,url);assert.equal(manager.get().error,'Try again');assert.throws(()=>manager.request({}),/context/);
});

test('a brief follow-up does not discard the scene being generated for the topic',async t=>{
 let finishFirst;const {manager}=await fixture(t,async input=>{if(input.context==='Ocean')return new Promise(r=>finishFirst=r);assert.equal(input.currentScene,'Ocean reef');return null});
 manager.request('Ocean');await until(()=>finishFirst);manager.request('Thank you');finishFirst(image('Ocean reef'));await until(()=>manager.get().status==='ready');assert.equal(manager.get().title,'Ocean reef');assert.ok(manager.get().url);
});

test('a reset during image saving cannot publish the old image afterward',async t=>{
 const original=fs.writeFile;let finishWrite;const {manager}=await fixture(t,async()=>image('Ocean'));
 t.mock.method(fs,'writeFile',async(...args)=>{await new Promise(resolve=>finishWrite=resolve);return original(...args)});
 manager.request('Ocean');await until(()=>finishWrite);manager.configure({reset:true});finishWrite();await wait(15);
 assert.equal(manager.get().url,null);assert.equal(manager.get().title,'Studio');assert.equal(manager.get().status,'idle');
});

test('double-clicking the same scene does not queue duplicate image generation',async t=>{
 let complete,calls=0;const {manager}=await fixture(t,async()=>{calls++;return new Promise(resolve=>complete=resolve)});
 manager.request('Ocean',{force:true});await until(()=>complete);manager.request('Ocean',{force:true});complete(image('Ocean'));await until(()=>manager.get().status==='ready');await wait(10);assert.equal(calls,1);
});
