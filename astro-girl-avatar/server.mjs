import http from 'node:http';
import {createBackgroundManager} from './background-server.mjs';
import {loadAPIKey,sessionConfig,createRealtimeCall} from './realtime-server.mjs';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {cloneDefault,mergeState} from './viewer/state.js';
const root=path.dirname(fileURLToPath(import.meta.url));
const manifest=JSON.parse(fs.readFileSync(path.join(root,'assets/character.json')));
const port=Number(process.env.PORT||8847),clients=new Set();let state=cloneDefault();
const mime={'.html':'text/html','.js':'text/javascript','.json':'application/json','.glb':'model/gltf-binary','.blend':'application/octet-stream','.css':'text/css','.png':'image/png','.webp':'image/webp','.wav':'audio/wav','.md':'text/plain'};
const json=(res,status,value)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value))};
const backgrounds=createBackgroundManager({directory:path.join(root,'.generated-backgrounds'),onChange:value=>{for(const c of clients)c.write(`event: background\ndata: ${JSON.stringify(value)}\n\n`)}});
const broadcast=()=>{for(const c of clients)c.write(`data: ${JSON.stringify(state)}\n\n`)};
const server=http.createServer(async(req,res)=>{
 const host=req.headers.host,origin=req.headers.origin;
 const allowed=[`127.0.0.1:${port}`,`localhost:${port}`];
 if(!allowed.includes(host)||(origin&&!allowed.map(x=>'http://'+x).includes(origin)))return json(res,403,{error:'Local same-origin requests only'});
 const url=new URL(req.url,'http://'+host),route=url.pathname;
 if(req.method==='GET'&&route==='/events'){
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive'});res.write(`data: ${JSON.stringify(state)}\n\nevent: background\ndata: ${JSON.stringify(backgrounds.get())}\n\n`);clients.add(res);
  const heartbeat=setInterval(()=>res.write(': keepalive\n\n'),15000);req.on('close',()=>{clearInterval(heartbeat);clients.delete(res)});return;
 }
 if(req.method==='GET'&&route==='/api/background')return json(res,200,backgrounds.get());
 if(req.method==='POST'&&['/api/background/context','/api/background'].includes(route)){
  try{
   let body='';for await(const chunk of req){body+=chunk;if(body.length>16384)return json(res,413,{error:'Request too large'})}
   const input=JSON.parse(body||'{}');if(!input||typeof input!=='object'||Array.isArray(input))throw new Error('Expected an object');
   const allowed=route.endsWith('/context')?['context','force']:['enabled','reset'];
   if(Object.keys(input).some(key=>!allowed.includes(key)))throw new Error('Unknown background field');
   if(input.force!==undefined&&typeof input.force!=='boolean')throw new Error('force must be a boolean');
   const result=route.endsWith('/context')?backgrounds.request(input.context,{force:input.force}):backgrounds.configure(input);
   return json(res,route.endsWith('/context')?202:200,result);
  }catch(e){return json(res,400,{error:e.message})}
 }
 if(req.method==='GET'&&route==='/api/realtime/status')return json(res,200,{configured:!!loadAPIKey(),model:sessionConfig(manifest).model,voice:'marin'});
 if(req.method==='POST'&&route==='/api/realtime/session'){
  try{
   let sdp='';for await(const chunk of req){sdp+=chunk;if(sdp.length>65536)return json(res,413,{error:'WebRTC offer too large'})}
   const answer=await createRealtimeCall(sdp,manifest);
   res.writeHead(201,{'Content-Type':'application/sdp','Cache-Control':'no-store'});return res.end(answer);
  }catch(e){return json(res,e.status||502,{error:e.name==='TimeoutError'?'Realtime connection timed out. Please retry.':e.message})}
 }
 if(req.method==='GET'&&route==='/health')return json(res,200,{status:'ok',character:manifest.name,clients:clients.size});
 if(req.method==='GET'&&['/api/state','/state'].includes(route))return json(res,200,state);
 if(req.method==='POST'&&['/api/state','/api/reset','/state'].includes(route)){
  try{
   let body='';for await(const chunk of req){body+=chunk;if(body.length>16384)return json(res,413,{error:'Request too large'})}
   let patch=body?JSON.parse(body):{};
   // Compatibility with the earlier local canvas prototype's level/mode contract.
   if(route==='/state'&&'level'in patch)patch={mouth:{mode:'audio',level:patch.level}};
   state=route==='/api/reset'?cloneDefault():mergeState(state,patch,manifest);broadcast();return json(res,200,state);
  }catch(e){return json(res,400,{error:e.message})}
 }
 if(req.method!=='GET'&&req.method!=='HEAD')return json(res,405,{error:'Method not allowed'});
 let relative;
 if(route==='/')relative='viewer/index.html';
 else if(route==='/stage')relative='viewer/stage.html';
 else if(/^\/backgrounds\/[0-9a-f-]{36}\.webp$/.test(route))relative='.generated-backgrounds/'+route.split('/').pop();
 else if(route.startsWith('/viewer/')||route.startsWith('/assets/')||route.startsWith('/previews/'))relative=route.slice(1);
 else if(route.startsWith('/vendor/three/'))relative='node_modules/three/'+route.slice('/vendor/three/'.length);
 else if(route==='/research.md'||route==='/README.md')relative=route.slice(1);
 else return json(res,404,{error:'Not found'});
 const file=path.resolve(root,relative);
 if(!file.startsWith(root+path.sep))return json(res,403,{error:'Invalid path'});
 try{const stat=await fs.promises.stat(file);if(!stat.isFile())throw new Error();res.writeHead(200,{'Content-Type':mime[path.extname(file)]||'application/octet-stream','Content-Length':stat.size,'Cache-Control':'no-cache','X-Content-Type-Options':'nosniff'});if(req.method==='HEAD')return res.end();fs.createReadStream(file).pipe(res)}catch{return json(res,404,{error:'Not found'})}
});
server.listen(port,'127.0.0.1',()=>console.log(`Astra controls: http://127.0.0.1:${port}/\nClean camera stage: http://127.0.0.1:${port}/stage`));
server.on('error',e=>{console.error(e.message);process.exit(1)});
