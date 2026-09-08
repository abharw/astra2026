"""Explicit app-level camera/AR test commands. Does not simulate OS touch input."""
import argparse, base64, json, pathlib, urllib.request, urllib.error
p=argparse.ArgumentParser();p.add_argument('action');p.add_argument('--x',type=float);p.add_argument('--y',type=float);p.add_argument('--operation');p.add_argument('--amount',type=float);p.add_argument('--part');p.add_argument('--output');a=p.parse_args()
c=json.loads((pathlib.Path(__file__).resolve().parent.parent/'private/control.json').read_text());url='http://127.0.0.1:8798'
body={k:v for k,v in vars(a).items() if v is not None and k!='output'}
r=urllib.request.Request(url+('/status' if a.action=='connection' else '/command'),data=None if a.action=='connection' else json.dumps(body).encode(),headers={'Authorization':'Bearer '+c['adminToken'],'Content-Type':'application/json'})
try:
 with urllib.request.urlopen(r,timeout=20) as response: result=json.load(response)
except urllib.error.HTTPError as e:
 print(e.read().decode());raise SystemExit(1)
if 'image' in result:
 image=result.pop('image')
 if a.output:
  path=pathlib.Path(a.output);path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(base64.b64decode(image));result['savedImage']=str(path.resolve())
 else:result['imageBytes']=len(base64.b64decode(image))
print(json.dumps(result,indent=2))
