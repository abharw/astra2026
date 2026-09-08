"""Encode the complete reference with explicit sRGB-to-Rec.709 conversion."""
import json,subprocess
from pathlib import Path
root=Path(__file__).resolve().parent
expected=json.loads((root/'floor-plan.json').read_text())['camera']['frames']
frames=root/'maze-blocking-frames'
missing=[i for i in range(1,expected+1) if not (frames/f'frame-{i:04}.png').is_file()]
if missing:raise SystemExit(f'Missing {len(missing)} source frames, first: {missing[0]}')
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-framerate','24','-i',str(frames/'frame-%04d.png'),'-frames:v',str(expected),'-vf','scale=in_range=pc:out_range=tv:out_color_matrix=bt709,format=yuv444p,colorspace=iall=bt709:itrc=srgb:all=bt709:range=tv:format=yuv420p','-c:v','libx264','-crf','15','-preset','fast','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-movflags','+faststart','-y',str(root/'blender-motion-reference.mp4')],check=True)
