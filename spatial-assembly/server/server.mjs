import fs from 'node:fs';
import {startBridge} from './bridge.mjs';
const key=process.env.OPENAI_API_KEY;
if(!key){console.error('OPENAI_API_KEY is required. Use launch.py for a hidden prompt.');process.exit(1);}
const path=process.env.BRIDGE_CONFIG || new URL('../private/connection.json',import.meta.url);
const config=JSON.parse(fs.readFileSync(path));
if(typeof config.token!=='string'||config.token.length<24)throw Error('Pairing token must contain at least 24 characters');
startBridge({key,token:config.token,port:Number(process.env.PORT || 8796),model:process.env.RECONSTRUCTION_MODEL || 'gpt-6-astra',voiceModel:process.env.REALTIME_MODEL || 'gpt-realtime-2.1',log:(event,details)=>console.log(JSON.stringify({time:new Date().toISOString(),event,...details}))});
