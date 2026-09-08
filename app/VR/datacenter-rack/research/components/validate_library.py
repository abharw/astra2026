from pathlib import Path
import json,datetime,hashlib,collections
root=Path(__file__).resolve().parents[2];r=root/'research/components'
a=json.loads((root/'source/component-library.json').read_text());errors=[]
for k,c in a['components'].items():
 if k!=c['component_key']:errors.append({'key_mismatch':k})
 for f in ['manufacturer','manufacturer_part_number','function','how_it_works','internal_parts','evidence_level','sources','origins','training_context','uncertainties']:
  if f not in c:errors.append({'key':k,'missing_field':f})
 for x in c['sources']:
  if 'path' in x and not (root/x['path']).exists():errors.append({'key':k,'missing_source':x['path']})
for ref,x in a['instances_by_refdes'].items():
 for k in x['component_keys']:
  if k not in a['components']:errors.append({'refdes':ref,'unknown_key':k})
for v in a['source_inputs']:
 p=root/v['path']
 if hashlib.sha256(p.read_bytes()).hexdigest()!=v['sha256']:errors.append({'hash_mismatch':str(p)})
expected={'U1':'PE38993-51BC0-1H','U10':'PE38993-51BC0-1H','U14':'AST2500A2-GP','U17':'MT40A512M16JY-083E:B','U13':'BCM54612EB1KMLG','LOM1':'BCM5719A1KFBG','J27':'42819-4233','DIMM00':'10140702-0302K11LF','DIMM01':'10140702-0301K11LF'}
landmarks={}
for ref,mpn in expected.items():
 x=a['instances_by_refdes'][ref];parts=[a['components'][k]['manufacturer_part_number'] for k in x['component_keys']]
 landmarks[ref]={'mpns':parts,'population_status':x['population_status']}
 if parts!=[mpn]:errors.append({'unexpected_identity':ref,'observed':parts})
result={'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':['component key consistency','required metadata fields','local source paths','instance links','source input hashes','landmark EVT3 identities'],'components':len(a['components']),'instances':len(a['instances_by_refdes']),'population_counts':dict(collections.Counter(x['population_status'] for x in a['instances_by_refdes'].values())),'landmarks':landmarks,'errors':errors,'scope':'Metadata integrity only; not visual, physical or engineering acceptance'}
(r/'validation.json').write_text(json.dumps(result,indent=2)+'\n')
(root/'logs/component-research-actions.jsonl').open('a').write(json.dumps({'recorded_at':result['checked_at'],'event':'component_library_validation','owner':'rack_component_knowledge','result':result})+'\n')
print(json.dumps({'components':result['components'],'instances':result['instances'],'errors':errors,'population_counts':result['population_counts']},indent=2))
if errors:raise SystemExit(1)
