"""Launch the exterior-only file and its question controls on this machine."""
from pathlib import Path
import os,subprocess,json
ROOT=Path(__file__).resolve().parents[1]
choices=[os.environ.get('BLENDER_BIN'),str(ROOT.parent.parent/'internet-revolution/engineering/blender-startup-20260908/candidate-build/extracted/Blender/Blender.app/Contents/MacOS/Blender'),'/Applications/Blender.app/Contents/MacOS/Blender']
binary=next((x for x in choices if x and Path(x).is_file()),None)
if not binary:raise SystemExit('Set BLENDER_BIN to the Blender executable, then run again.')
asset=ROOT/'models/lazy/rack-exterior.blend'
if not asset.is_file():raise SystemExit('The exterior asset is missing. Fetch Git LFS objects or build package_assets.py first.')
runtime=ROOT/'.runtime';runtime.mkdir(exist_ok=True)
with (runtime/'blender-gui.log').open('w') as log:
    proc=subprocess.Popen([binary,str(asset),'--python',str(ROOT/'source/start_rack_lab.py')],stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
print(json.dumps({'pid':proc.pid,'asset':str(asset),'detail_preloaded':False}))
