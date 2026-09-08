import sys,json
from pathlib import Path
import bpy
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'source'))
from processor_study import build_processor_study,set_exploded
col=bpy.data.collections.new('Processor study validation');bpy.context.scene.collection.children.link(col)
root,meta=build_processor_study(col)
parts=[o for o in col.objects if 'part_id' in o]
assert len({o['part_id'] for o in parts})==len(parts)
assert sum(o.get('semantic_type')=='core' for o in col.objects)==24
assert sum(o.get('semantic_type')=='substrate_layer' for o in col.objects)==16
assert sum(o.get('semantic_type')=='contact_symbol' for o in col.objects)==144
substrate=next(o for o in col.objects if o.get('semantic_type')=='substrate_layer');assert all(abs(v-.0685)<1e-8 for v in substrate.dimensions[:2])
initial={o.name:tuple(o.location) for o in col.objects};set_exploded(root,1);assert tuple(substrate.location)!=initial[substrate.name] or substrate.name.endswith('bottom build-up')
set_exploded(root,0);assert all(tuple(o.location)==initial[o.name] for o in col.objects)
set_exploded(root,1);bpy.context.view_layer.update();meta['validation']={'objects':len(col.objects),'unique_part_ids':len(parts),'cores':24,'substrate_bands':16,'contact_symbols':144,'reversible_explosion':True,'package_width_mm':substrate.dimensions.x*1000};(ROOT/'research/cad-diagnostics/processor-study-validation.json').write_text(json.dumps(meta,indent=2)+'\n');bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'research/cad-diagnostics/processor-study-validation.blend'));print(json.dumps(meta['validation']))
