"""Rasterize original EVT3 Gerber layers in the original ODB XY frame.

Uses Gerbonara 1.6.3 and CairoSVG. Original source-layers are immutable.
Legacy primitive 22 conversion follows Ucamco specification section 8.2.5:
https://www.ucamco.com/files/downloads/file_en/451/gerber-layer-format-specification-revision-2021-11_en.pdf
The primitive is exactly a rectangle specified by lower-left; primitive 21
uses the same dimensions/rotation and the translated center. Numeric inputs
are required here; a new unsupported expression causes failure.
"""
from pathlib import Path
from decimal import Decimal
import argparse, datetime, gc, hashlib, json, re, time
from gerbonara.rs274x import GerberFile
from gerbonara.utils import MM
import cairosvg
from PIL import Image, ImageChops

BASE = Path(__file__).resolve().parent
LAYERS = {'top-copper':'MB-CMP.ART','bottom-copper':'MB-SLD.ART',
          'top-mask-openings':'MB-TMK.ART','bottom-mask-openings':'MB-BMK.ART',
          'top-silkscreen':'MB-TSK.ART','bottom-silkscreen':'MB-BSK.ART'}
BOUNDS = ((0.0,0.0),(330.2,563.88))

def log(detail, **fields):
    with (BASE.parents[1]/'logs/pcb-population-actions.jsonl').open('a') as f:
        f.write(json.dumps({'recorded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'actor':'rack_openhardware_research','detail':detail,**fields})+'\n')

def normalize_legacy(text):
    def replace(m):
        fields=m.group(1).split(',')
        if len(fields)!=6: raise ValueError('unexpected legacy rectangle argument count')
        exposure,width,height,x,y,rotation=fields
        cx=Decimal(x)+Decimal(width)/2;cy=Decimal(y)+Decimal(height)/2
        return '21,'+','.join([exposure,width,height,str(cx),str(cy),rotation])+'*'
    return re.subn(r'(?m)^22,([^*]+)\*',replace,text)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--height',type=int,default=8192)
    ap.add_argument('--layers',nargs='*',choices=list(LAYERS),default=list(LAYERS))
    args=ap.parse_args();out=BASE/'textures';out.mkdir(exist_ok=True)
    normalized=BASE/'normalized-layers';normalized.mkdir(exist_ok=True)
    width=round(args.height*330.2/563.88)
    receipt={'schema_version':1,'bounds_mm':BOUNDS,'pixel_dimensions':[width,args.height],
        'uv_mapping':'u=x_mm/330.2, v=y_mm/563.88. PNG row0 is maximum ODB y. Both sides use identical XY; do not mirror bottom u.',
        'channel_meaning':'white=source dark polarity feature; black=no feature. Mask white means mask opening, not green mask.',
        'source_profile':'13.0 x 22.2 inch ODB cad profile bounds; final mesh must follow source profile/cutouts.',
        'limitation':'maps crop fabrication legends outside board bounds; rectangular maps do not themselves cut the board outline or drill holes.',
        'renderer':'Gerbonara 1.6.3 + CairoSVG 2.9.1; grayscale PNG','layers':[]}
    for label, filename in LAYERS.items():
        if label not in args.layers: continue
        start=time.monotonic();src=BASE/'source-layers'/filename
        text,converted=normalize_legacy(src.read_text())
        (normalized/filename).write_text(text)
        layer=GerberFile.from_string(text,filename=filename)
        print(label,'parsed',len(layer.objects),'objects',flush=True)
        record={'layer':label,'source_file':str(src),'source_sha256':hashlib.sha256(src.read_bytes()).hexdigest(),
            'primitive22_to21_count':converted,'object_count':len(layer.objects),
            'original_feature_bounds_mm':layer.bounding_box(MM)}
        svg=str(layer.to_svg(force_bounds=BOUNDS,fg='white',bg='black'))
        target=out/(label+'.png')
        cairosvg.svg2png(bytestring=svg.encode(),write_to=str(target),output_width=width,
            output_height=args.height,background_color='black')
        with Image.open(target) as im: grayscale=im.convert('L')
        grayscale.save(target,optimize=True)
        preview=grayscale.copy();preview.thumbnail((1200,2048));preview.save(out/(label+'-preview.png'))
        record.update({'path':str(target),'bytes':target.stat().st_size,
            'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
            'extrema':grayscale.getextrema(),'nonzero_pixel_bbox':grayscale.getbbox(),
            'seconds':time.monotonic()-start})
        receipt['layers'].append(record)
        (out/'texture-receipt.json').write_text(json.dumps(receipt,indent=2))
        log('rasterized source Gerber layer',**record)
        print(label,'done',round(record['seconds'],2),'seconds',flush=True)
        del text,layer,svg,grayscale,preview;gc.collect()
    print('complete',flush=True)

if __name__=='__main__':main()
