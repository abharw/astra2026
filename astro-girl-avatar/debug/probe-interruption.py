"""Replay quiet synthetic voice during a live response; never records a microphone."""
import json,ssl,time,wave,base64,sys
from pathlib import Path
import websocket,numpy as np
root=Path(__file__).resolve().parents[1]
key=(Path.home()/'.config/astra-girl/openai-api-key').read_text().strip()
config=json.loads((root/'debug/realtime-baseline-config.json').read_text())
variant='protected' if '--protected' in sys.argv else 'baseline'
if '--current' in sys.argv:config=json.loads((root/'debug/realtime-current-config.json').read_text());variant='current'
if variant=='protected':config['audio']['input']['turn_detection']['interrupt_response']=False
if '--fast' in sys.argv:config['reasoning']={'effort':'minimal'};variant='fast'
with wave.open(str(root/'previews/voice-demo.wav')) as f:
 rate=f.getframerate();pcm=np.frombuffer(f.readframes(f.getnframes()),dtype='<i2').astype(float)/32768
pcm=np.interp(np.arange(int(len(pcm)*24000/rate))*rate/24000,np.arange(len(pcm)),pcm)
pcm=pcm[:24000*4];pcm=pcm/max(abs(pcm))*.10
chunks=[base64.b64encode((pcm[i:i+2400]*32767).astype('<i2').tobytes()).decode() for i in range(0,len(pcm),2400)]
ws=websocket.create_connection('wss://api.openai.com/v1/realtime?model='+config['model'],header=['Authorization: Bearer '+key],timeout=15)
ws.send(json.dumps({'type':'session.update','session':config}))
while True:
 e=json.loads(ws.recv())
 if e['type']=='error':raise RuntimeError(e['error'].get('code','API error'))
 if e['type']=='session.updated':break
ws.send(json.dumps({'type':'response.create','response':{'instructions':'Explain the solar system in a continuous detailed paragraph of 150 words. Do not call tools.','tool_choice':'none'}}))
start=time.monotonic();index=0;last=0;events=[];first_audio=None;response_id=None
ws.settimeout(.03)
while time.monotonic()-start<8:
 now=time.monotonic()-start
 if response_id and index<len(chunks) and now-last>=.1:
  ws.send(json.dumps({'type':'input_audio_buffer.append','audio':chunks[index]}));index+=1;last=now
 try:e=json.loads(ws.recv())
 except websocket.WebSocketTimeoutException:continue
 kind=e['type']
 if kind=='response.created' and response_id is None:response_id=e['response']['id']
 if kind=='response.output_audio.delta' and first_audio is None:first_audio=round(now,3)
 if kind in ['input_audio_buffer.speech_started','input_audio_buffer.speech_stopped','response.done','error']:
  events.append({'time':round(now,3),'type':kind,'status':e.get('response',{}).get('status'),'original':e.get('response',{}).get('id')==response_id,'code':e.get('error',{}).get('code')})
ws.close()
result={'first_audio_seconds':first_audio,'events':events,'background_cancelled_reply':any(x['original'] and x['status']=='cancelled' for x in events)}
(root/('debug/interruption-'+variant+'.json')).write_text(json.dumps(result,indent=2))
print(json.dumps(result))
if '--assert' in sys.argv:assert not result['background_cancelled_reply'] and first_audio is not None and first_audio<2.5, 'Background interruption or slow response reproduced'
