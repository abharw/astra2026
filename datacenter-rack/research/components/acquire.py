from pathlib import Path
import urllib.request,hashlib,json,datetime,subprocess
ROOT=Path(__file__).resolve().parent
LOG=ROOT.parents[1]/'logs/component-research-actions.jsonl'
SOURCES=[
('power9-lagrange-v1.7.pdf','https://wiki.raptorcs.com/w/images/d/df/POWER9_LaGrange_ds_v17_28MAR2019_pub.pdf','IBM/OpenPOWER primary-authored datasheet on Raptor Computing mirror; document copyright retained; no general redistribution license established.'),
('power9-hotchips2016.pdf','https://old.hotchips.org/wp-content/uploads/hc_archives/hc28/HC28.23-Tuesday-Epub/HC28.23.90-High-Perform-Epub/HC28.23.921-.POWER9-Thompto-IBM-final.pdf','IBM presentation published by Hot Chips; copyright IBM 2016; research reference, no asset redistribution license established.'),
('ti-ucd90160.pdf','https://www.ti.com/lit/ds/symlink/ucd90160.pdf','TI primary public datasheet; retain notices; no general redistribution license established.'),
('vicor-vtm48mp012t130aa0.pdf','https://www.vicorpower.com/documents/datasheets/ds_VTM48MP012T130AA0.pdf','Vicor primary public datasheet; retain notices; no general redistribution license established.'),
('kingston-kvr24r17d4-32.pdf','https://www.kingston.com/dataSheets/kvr24r17d4_32.pdf','Kingston primary public datasheet; copyright retained; illustrative compatible-class module, not confirmed EVT population.'),
('renesas-isl68137.pdf','https://www.renesas.com/en/document/dst/isl68137-datasheet','Renesas/Intersil primary public datasheet; retain notices; no general redistribution license established.'),
('broadcom-bcm5719.pdf','https://docs.broadcom.com/doc/5719-PB01-R','Broadcom primary public product brief; retain notices; no general redistribution license established.')]
for name,url,rights in SOURCES:
 start=datetime.datetime.now(datetime.timezone.utc).isoformat(); p=ROOT/'originals'/name
 try:
  if not p.exists():
   with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=40) as r: data=r.read()
   if not data.startswith(b'%PDF'): raise ValueError('Not a PDF')
   p.write_bytes(data)
  data=p.read_bytes(); record={'id':name.removesuffix('.pdf'),'retrieved_at':start,'url':url,'path':str(p),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'rights':rights,'status':'downloaded-verified-header','method':'Python urllib HTTPS; SHA256; pdftotext'}
  (ROOT/'source-register.jsonl').open('a').write(json.dumps(record)+'\n')
  subprocess.run(['pdftotext','-layout',str(p),str(p.with_suffix('.txt'))],check=True)
  LOG.open('a').write(json.dumps({'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'started_at':start,'owner':'rack_component_knowledge','event':'acquire_primary_reference',**record})+'\n')
  print(name,len(data))
 except Exception as e:
  LOG.open('a').write(json.dumps({'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'owner':'rack_component_knowledge','event':'acquire_failed','url':url,'error':str(e)})+'\n');print(name,str(e))
