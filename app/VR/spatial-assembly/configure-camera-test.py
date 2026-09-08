"""Pair the optional foreground-only physical-device camera test link."""
import argparse,json,pathlib,plistlib,secrets
p=argparse.ArgumentParser();p.add_argument('url',help='HTTPS tunnel URL for localhost:8798');a=p.parse_args()
if not a.url.startswith('https://'):raise SystemExit('HTTPS required')
root=pathlib.Path(__file__).resolve().parent;file=root/'private/control.json';file.parent.mkdir(exist_ok=True)
c=json.loads(file.read_text()) if file.exists() else {'deviceToken':secrets.token_urlsafe(32),'adminToken':secrets.token_urlsafe(32)}
c['url']=a.url.rstrip('/');file.write_text(json.dumps(c));file.chmod(0o600)
plist=root/'ios/SpatialAssembly/Connection.plist'
if not plist.exists():raise SystemExit('Run configure.py first to pair the generation bridge')
config=plistlib.loads(plist.read_bytes());config.update(controlURL=c['url'],controlToken=c['deviceToken']);plist.write_bytes(plistlib.dumps(config));plist.chmod(0o600)
quest=root.parent/'quest/Assets/StreamingAssets/control.json'
quest.parent.mkdir(parents=True,exist_ok=True);quest.write_text(json.dumps({'url':c['url'],'token':c['deviceToken']}));quest.chmod(0o600)
print('Mac camera test paired for iPhone and Quest. Rebuild the target app; keep relay and tunnel running. One device can connect at a time.')
