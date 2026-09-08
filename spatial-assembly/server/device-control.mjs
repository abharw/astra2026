import http from 'node:http';
import fs from 'node:fs';
import {randomUUID,timingSafeEqual} from 'node:crypto';
import {WebSocketServer,WebSocket} from 'ws';
import {pathToFileURL} from 'node:url';
const equal=(a,b)=>typeof a==='string'&&typeof b==='string'&&Buffer.byteLength(a)===Buffer.byteLength(b)&&timingSafeEqual(Buffer.from(a),Buffer.from(b));
export function startDeviceControl({deviceToken,adminToken,port=8798}){
 let phone=null;const pending=new Map();
 const server=http.createServer(async(req,res)=>{
  res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');
  const respond=(status,value)=>{res.writeHead(status);res.end(JSON.stringify(value));};
  if(!equal(req.headers.authorization,'Bearer '+adminToken)){respond(401,{error:'Unauthorized'});return;}
  if(req.method==='GET'&&req.url==='/status'){respond(200,{connected:phone?.readyState===WebSocket.OPEN,pending:pending.size});return;}
  if(req.method!=='POST'||req.url!=='/command'){respond(404,{error:'Not found'});return;}
  if(phone?.readyState!==WebSocket.OPEN){respond(409,{error:'Enable Mac camera test in the unlocked phone app'});return;}
  let raw='';for await(const chunk of req){raw+=chunk;if(raw.length>16000){respond(413,{error:'Command too large'});return;}}
  let command;try{command=JSON.parse(raw);}catch{respond(400,{error:'Invalid JSON'});return;}
  const allowed=['state','snapshot','drag','ask','tap','reconstruct','cancel','manipulate','voice.start','voice.stop','explain','refine'];
  if(!allowed.includes(command.action)){respond(400,{error:'Unsupported action'});return;}
  if(command.action==='tap'&&(!Number.isFinite(command.x)||!Number.isFinite(command.y)||command.x<0||command.x>1||command.y<0||command.y>1)){respond(400,{error:'Tap coordinates must be normalized 0–1'});return;}
  if(command.action==='drag'&&![command.fromX,command.fromY,command.x,command.y].every(v=>Number.isFinite(v)&&v>=0&&v<=1)){respond(400,{error:'Drag coordinates must be normalized 0–1'});return;}
  if(command.action==='ask'&&(typeof command.question!=='string'||!command.question.trim()||command.question.length>2000)){respond(400,{error:'Provide a question of 1–2000 characters'});return;}
  const id=randomUUID();const timer=setTimeout(()=>{pending.delete(id);respond(504,{error:'Phone acknowledgment timed out'});},15000);
  pending.set(id,{timer,respond});phone.send(JSON.stringify({...command,type:'test.command',id}));
 });
 const wss=new WebSocketServer({noServer:true,maxPayload:12*1024*1024});
 server.on('upgrade',(req,socket,head)=>{if(req.url!=='/session'||!equal(req.headers.authorization,'Bearer '+deviceToken)){socket.destroy();return;}wss.handleUpgrade(req,socket,head,s=>wss.emit('connection',s));});
 wss.on('connection',socket=>{
  if(phone?.readyState===WebSocket.OPEN){socket.close(1008,'A phone is already connected');return;}phone=socket;socket.send(JSON.stringify({type:'connected'}));
  socket.on('message',raw=>{let e;try{e=JSON.parse(raw);}catch{return;}if(e.type==='ping'){socket.send(JSON.stringify({type:'pong'}));return;}if(e.type!=='test.result')return;const item=pending.get(e.id);if(!item)return;clearTimeout(item.timer);pending.delete(e.id);item.respond(200,e);});
  socket.on('close',()=>{if(phone===socket){phone=null;for(const item of pending.values()){clearTimeout(item.timer);item.respond(409,{error:'Phone disconnected'});}pending.clear();}});
 });
 server.listen(port,'127.0.0.1');return {server,wss,close(){for(const client of wss.clients)client.terminate();wss.close();server.close();}};
}
if(import.meta.url===pathToFileURL(process.argv[1]||'').href){const config=JSON.parse(fs.readFileSync(new URL('../private/control.json',import.meta.url)));startDeviceControl({...config,port:Number(process.env.CONTROL_PORT||8798)});console.log('Device camera test relay listening on localhost:8798; no frames are persisted');}
