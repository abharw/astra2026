import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
test('HTTP controls validate atomically and retain legacy audio compatibility',async()=>{
 const process=spawn(globalThis.process.execPath,['server.mjs'],{cwd:new URL('..',import.meta.url),env:{...globalThis.process.env,PORT:'18847'},stdio:['ignore','pipe','pipe']});
 try{
  await Promise.race([once(process.stdout,'data'),new Promise((_,reject)=>{const timer=setTimeout(()=>reject(new Error('Server did not start')),5000);timer.unref()})]);
  const url='http://127.0.0.1:18847',post=(route,body,extra={})=>fetch(url+route,{method:'POST',headers:{'Content-Type':'application/json',...extra},body:JSON.stringify(body)});
  const valid=await post('/api/state',{expression:'wink',motion:{name:'wave'},mouth:{mode:'viseme',viseme:'aa'}});assert.equal(valid.status,200);const state=await valid.json();
  const invalid=await post('/api/state',{expression:'angry',motion:{name:'missing'}});assert.equal(invalid.status,400);assert.deepEqual(await fetch(url+'/api/state').then(r=>r.json()),state);
  const legacy=await post('/state',{level:.65});assert.equal((await legacy.json()).mouth.level,.65);
  assert.equal((await post('/api/state',{expression:'neutral'},{Origin:'https://example.com'})).status,403);
  assert.equal((await post('/api/reset',{}).then(r=>r.json())).expression,'neutral');
 }finally{process.kill();await once(process,'exit')}
});
