"""Send a finite question/inspect operation to the active local Blender scene."""
from pathlib import Path
import argparse,json,urllib.request,uuid
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('question',nargs='?');p.add_argument('--state',action='store_true');p.add_argument('--intent');p.add_argument('--server');p.add_argument('--request-id');a=p.parse_args()
cfg=json.loads((ROOT/'.runtime/bridge.json').read_text())
payload={'action':'state'} if a.state else {'action':'intent','intent':json.loads(a.intent)} if a.intent else {'action':'question','question':a.question,'server_id':a.server}
payload['request_id']=a.request_id or str(uuid.uuid4())
req=urllib.request.Request(f"http://127.0.0.1:{cfg['port']}/action",data=json.dumps(payload).encode(),headers={'Content-Type':'application/json','X-RackLab-Token':cfg['token']},method='POST')
with urllib.request.urlopen(req,timeout=190) as response:print(response.read().decode())
