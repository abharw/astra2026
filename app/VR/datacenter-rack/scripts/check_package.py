"""Read-only package and protocol preflight; no Blender launch or renders."""
from pathlib import Path
import ast,json,struct,sys,zipfile
ROOT=Path(__file__).resolve().parents[1]
def need(value,message):
    if not value:raise SystemExit(message)
m=json.loads((ROOT/'models/lazy/manifest.json').read_text())
for filename in ['rack-exterior.blend','parts-library.blend','exterior-library.blend']:
    p=ROOT/'models/lazy'/filename
    with p.open('rb') as f: header=f.read(20)
    need(header.startswith(b'BLENDER') or header.startswith(b'\x28\xb5\x2f\xfd') or header.startswith(b'\x1f\x8b'),f'{p}: missing binary; run git lfs pull')
for aid in ['rack.exterior','server.exterior','server.mechanical','server.motherboard','server.memory','processor.study']:
    row=m['assets'][aid];need((ROOT/'models/lazy'/row['library']).is_file(),aid+' library missing');need(bool(row['collection']),aid+' collection missing')
for p in (ROOT/'source').glob('*.py'):ast.parse(p.read_text(),filename=str(p))
sys.path.insert(0,str(ROOT/'source'))
from question_context import resolve_question
q=resolve_question('Show U14 in server 3')
need(q['intent']['asset_id']=='server.motherboard' and q['intent']['part_id']=='pcb.U14' and q['intent']['server_id']=='rack01.server03','Question protocol mismatch')
p=ROOT/'models/lazy/rack-exterior.glb';data=p.read_bytes();need(data[:4]==b'glTF','GLB not fetched');n=struct.unpack_from('<I',data,12)[0];g=json.loads(data[20:20+n]);ids={o.get('extras',{}).get('part_id','') for o in g['nodes']}
need(all(f'rack01.server{i:02}' in ids for i in range(1,19)),'GLB missing server IDs')
with zipfile.ZipFile(ROOT/'models/lazy/rack-exterior.usdz') as z:need(z.testzip() is None,'USDZ invalid')
print(json.dumps({'status':'ok','detail_assets':4,'servers':18,'question_protocol':'U14/server3 resolved','renders_required':False}))
