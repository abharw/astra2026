"""Start the requested preview only after the exterior package is fully saved."""
from pathlib import Path
import subprocess,time,sys
ROOT=Path(__file__).resolve().parents[1]
for attempt in range(120):
    if (ROOT/'models/lazy/package-receipt.json').exists():break
    time.sleep(2)
else:raise SystemExit('Exterior package has not completed yet.')
binary=ROOT.parent.parent/'internet-revolution/engineering/blender-startup-20260908/candidate-build/extracted/Blender/Blender.app/Contents/MacOS/Blender'
cmd=[str(binary),'-b',str(ROOT/'models/lazy/rack-exterior.blend'),'--threads','12','--python',str(ROOT/'source/render_default.py')]
raise SystemExit(subprocess.call(cmd))
