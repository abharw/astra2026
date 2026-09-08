"""Ground-truth map from the exact maze source; never burn into the test video."""
import json,math
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
root=Path(__file__).resolve().parent;data=json.loads((root/'floor-plan.json').read_text())
im=Image.new('RGB',(1440,1150),'#f4f3ee');d=ImageDraw.Draw(im)
def font(n):return ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',n)
def pt(x,y):return (520+x*44,520-y*44)
def rect(a,b,fill,outline=None,width=1):d.rectangle([pt(a[0],b[1]),pt(b[0],a[1])],fill=fill,outline=outline,width=width)
d.text((40,25),'Data-center maze: ground truth',font=font(35),fill='#192735');d.text((42,75),'Straight → left → right → left • 24 m route • 30-second regular POV video',font=font(21),fill='#55616b')
for i,j in data['floor_cells']:rect((i*.5,j*.5),((i+1)*.5,(j+1)*.5),'#dee3e3')
for a,b in data['wall_bounds_m']:rect(a,b,'#27313d')
for r in data['racks']:
 a,b=r['bounds_m'];rect(a,b,'#52646f',outline='#263945')
 x,y=pt(*r['position_m'][:2]);d.text((x-10,y-5),r['id'].replace('Bay ',''),font=font(10),fill='white')
route=[pt(*v) for v in data['route_points_m']];d.line(route,fill='#087f6c',width=7)
for i,(x,y) in enumerate(route):
 d.ellipse((x-8,y-8,x+8,y+8),fill='#f4f3ee',outline='#087f6c',width=3)
 if 0<i<len(route)-1:d.text((x+12,y+10),str(i),font=font(19),fill='#087f6c')
for i in range(len(route)-1):
 a,b=route[i],route[i+1];x=(a[0]+b[0])/2;y=(a[1]+b[1])/2;theta=math.atan2(b[1]-a[1],b[0]-a[0]);c=math.cos(theta);s=math.sin(theta)
 d.polygon([(x+13*c,y+13*s),(x-8*c+6*s,y-8*s-6*c),(x-8*c-6*s,y-8*s+6*c)],fill='#087f6c')
for lm,c in zip(data['landmarks'],['#db8a20','#258fa3','#bd3a3c','#318452']):
 x,y=pt(*lm['position_m'][:2]);d.ellipse((x-9,y-9,x+9,y+9),fill=c)
x,y=route[0];d.text((x+15,y-15),'START',font=font(17),fill='#087f6c');x,y=route[-1];d.text((x-27,y+17),'FINISH',font=font(17),fill='#087f6c')
lines=['CAMERA ROUTE','','0–6 s     Straight through aisle A','6–8 s     Pause; pan left at junction 1','8–13 s   Walk west through aisle B','13–15 s Pause; pan right at junction 2','15–20 s Walk north through aisle C','20–22 s Pause; pan left at junction 3','22–27 s Walk west through aisle D','27–30 s Stop and pan back','','PERMANENT LANDMARKS','','1   Amber wall panel','2   Cyan wall panel','3   Red wall panel','End   Green service door','','SETTINGS','','1.65 m eye height; 24 mm lens','24 fps; continuous motion; no cuts','Fixed walls, rack bays and ceiling','','TEST BOUNDARY','','Supply only the video to the mapper.','Keep this plan and camera poses','separate for checking its answer.']
for i,line in enumerate(lines):d.text((880,150+i*31),line,font=font(18 if i else 22),fill='#27313d')
d.text((40,1090),'Authored synthetic environment. Floor plan and camera poses are ground truth for the Blender reference only.',font=font(19),fill='#55616b')
im.save(root/'floor-plan.png')
