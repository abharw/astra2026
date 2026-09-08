from pathlib import Path
import urllib.request,hashlib,json,datetime,subprocess
r=Path(__file__).resolve().parent
jobs=[('micron-8gb-ddr4.pdf','https://www.micron.com/content/dam/micron/global/public/products/data-sheet/dram/ddr4/8gb_ddr4_dram.pdf'),('molex-428194233.pdf','https://www.molex.com/content/dam/molex/molex-dot-com/products/automated/en-us/salesdrawingpdf/428/42819/428194233_sd.pdf')]
for name,url in jobs:
 try:
  data=urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=20).read();assert data[:4]==b'%PDF';p=r/'originals'/name;p.write_bytes(data)
  rec={'id':p.stem,'retrieved_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'url':url,'path':str(p),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'rights':'Primary manufacturer document. Notices retained; no general redistribution license established.','status':'downloaded-verified-header'}
  (r/'source-register.jsonl').open('a').write(json.dumps(rec)+'\n');subprocess.run(['pdftotext','-layout',str(p),str(p.with_suffix('.txt'))],check=True)
  (r.parents[1]/'logs/component-research-actions.jsonl').open('a').write(json.dumps({'event':'detail_acquisition','owner':'rack_component_knowledge',**rec})+'\n');print(name,len(data))
 except Exception as e:
  (r.parents[1]/'logs/component-research-actions.jsonl').open('a').write(json.dumps({'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'event':'detail_acquisition_failed','owner':'rack_component_knowledge','url':url,'error':str(e)})+'\n');print(name,str(e))
