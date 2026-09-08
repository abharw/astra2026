"""Register the local inspection and question bridge without loading detail."""
from pathlib import Path
import sys
import bpy
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'source'))
import lazy_inspector,question_bridge
lazy_inspector.register();question_bridge.register()
for area in bpy.context.screen.areas:
    if area.type=='VIEW_3D':
        area.spaces.active.show_region_ui=True
        area.spaces.active.overlay.show_extras=False
        area.spaces.active.overlay.show_relationship_lines=False
        area.spaces.active.overlay.show_floor=False
        area.spaces.active.region_3d.view_perspective='CAMERA'
print('RACK_LAB_READY',lazy_inspector.refresh_stats(),flush=True)
