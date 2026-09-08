from PIL import Image,ImageDraw,ImageFont
from pathlib import Path
import math, html
OUT=Path('outputs'); OUT.mkdir(exist_ok=True)
INK='#20312f'; MUTED='#536461'; BLUE='#176c94'; AMBER='#a56a23'; BG='#faf9f5'
class Canvas:
 def __init__(self,w,h):
  self.w=w;self.h=h;self.im=Image.new('RGB',(w*2,h*2),BG);self.d=ImageDraw.Draw(self.im);self.svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}"><rect width="100%" height="100%" fill="{BG}"/>']
 def text(self,x,y,s,size=20,color=INK,bold=False):
  f=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial'+(' Bold' if bold else '')+'.ttf',size*2)
  self.d.text((x*2,y*2),s,font=f,fill=color)
  self.svg.append(f'<text x="{x}" y="{y+size*.88}" fill="{color}" font-family="Arial,sans-serif" font-size="{size}" font-weight="{700 if bold else 400}">{html.escape(s)}</text>')
 def line(self,xy,color=INK,width=3,dash=False):
  for (x1,y1),(x2,y2) in zip(xy,xy[1:]):
   if dash:
    l=math.hypot(x2-x1,y2-y1)
    for k in range(0,int(l),14):
     a=k/l;b=min(k+8,l)/l;self.d.line(((x1+(x2-x1)*a)*2,(y1+(y2-y1)*a)*2,(x1+(x2-x1)*b)*2,(y1+(y2-y1)*b)*2),fill=color,width=width*2)
   else:self.d.line((x1*2,y1*2,x2*2,y2*2),fill=color,width=width*2)
  pts=' '.join(f'{x},{y}' for x,y in xy); da=' stroke-dasharray="8 6"' if dash else ''
  self.svg.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}"{da}/>')
 def rect(self,x,y,w,h,fill='#edf1ec',stroke=AMBER,dash=True):
  self.d.rectangle((x*2,y*2,(x+w)*2,(y+h)*2),fill=fill)
  self.svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}"/>')
  if stroke:self.line([(x,y),(x+w,y),(x+w,y+h),(x,y+h),(x,y)],stroke,2,dash)
 def arrow(self,xy,color=BLUE,dash=False):
  self.line(xy,color,4,dash); x,y=xy[-1];p,q=xy[-2];a=math.atan2(y-q,x-p)
  self.line([(x-14*math.cos(a-.5),y-14*math.sin(a-.5)),(x,y),(x-14*math.cos(a+.5),y-14*math.sin(a+.5))],color,3)
 def save(self,name):
  self.im.save(OUT/(name+'.png'));(OUT/(name+'.svg')).write_text(''.join(self.svg)+'</svg>')

c=Canvas(1700,1120)
c.text(60,35,'A floor-plan hypothesis from one home video',36,bold=True)
c.text(60,85,'IMG_7958 2.MOV  •  57.79 seconds  •  Unmeasured schematic  •  Awaiting your corrections',21)
c.text(60,122,'Read left to right along the hall. “Left / right” below means while walking toward the dining room.',19,MUTED)
# Footprints are hypotheses, not measured geometry.
c.rect(65,320,325,420); c.text(90,435,'SITTING ROOM',24,bold=True);c.text(90,472,'6–19 s',19,MUTED)
c.rect(390,535,250,250);c.text(415,585,'STUDY / START',23,bold=True);c.text(415,619,'0–6 s',19,MUTED);c.text(415,665,'Shelving, desk,',18);c.text(415,691,'monitors, lamp',18)
c.rect(390,355,700,125,fill='#f0f3f5');c.text(425,373,'HALL / LANDING  •  19–46 s',22,bold=True);c.text(425,443,'Windows + local bends; straightened here for clarity',17,MUTED)
c.rect(410,205,190,150,fill='#e5e9e8');c.text(430,220,'STAIRS',21,bold=True);c.text(430,251,'Railing seen',17);c.text(430,276,'Lower floor unseen',16)
for y in range(305,350,9):c.line([(425,y),(580,y)],MUTED,1)
c.rect(695,175,215,180,fill='#e3f1f3');c.text(720,203,'BATHROOM',23,bold=True);c.text(720,237,'30–38 s',18,MUTED);c.text(720,274,'Shower • basin',18);c.text(720,301,'Toilet • window',18)
c.rect(695,480,260,260,fill='#efeaf1');c.text(720,550,'BEDROOM',23,bold=True);c.text(720,583,'39–42 s: threshold only',17,MUTED);c.text(720,634,'Bed at far side',18);c.text(720,661,'Dresser / mirror at right',17)
c.rect(1090,320,495,340,fill='#f4e9df');c.text(1170,425,'DINING ROOM',24,bold=True);c.text(1170,462,'46–49 s; 56–end',18,MUTED)
c.rect(1090,660,310,265,fill='#f6efd5');c.text(1115,716,'KITCHEN',24,bold=True);c.text(1115,750,'49–54 s',18,MUTED);c.text(1115,787,'Range / hood',18);c.text(1115,812,'Cabinets + fridge',18)
c.rect(1400,660,220,265,fill='#f0efdc');c.text(1420,706,'UTILITY AREA',20,bold=True);c.text(1420,742,'54–55 s',18,MUTED);c.text(1420,785,'Washer + window',17);c.text(1420,815,'Extent uncertain',17,AMBER)
# Wall anchors / openings
c.line([(67,410),(67,650)],BLUE,6);c.text(85,520,'Curtained bay',18);c.text(85,548,'Chairs + statue',17)
c.line([(85,738),(245,738)],INK,6);c.text(90,698,'Fireplace / TV side',17)
c.text(90,342,'Sofa + desk side',18)
c.line([(1185,322),(1385,322)],INK,6);c.text(1170,340,'Fireplace + mirror',18)
c.line([(1584,390),(1584,595)],BLUE,6);c.text(1400,519,'Bay windows',18);c.text(1400,547,'Dining table',18)
c.line([(1190,660),(1380,660)],INK,8);c.text(1170,625,'Peninsula / wide opening',17)
c.line([(1110,924),(1375,924)],INK,6);c.text(1105,881,'Appliance wall',18)
c.line([(800,355),(800,397)],BLUE,7);c.line([(800,437),(800,480)],BLUE,7)
c.arrow([(515,730),(355,730),(355,417),(1070,417)])
# Direction is stated above the schematic.
c.arrow([(1110,505),(1140,605),(1140,688)])
c.text(1090,955,'Kitchen lies to your RIGHT when entering dining.',20,BLUE,bold=True)
c.line([(600,480),(600,535)],AMBER,3,True);c.text(420,494,'Possible second study door?',16,AMBER)
c.text(60,838,'What is still imagined',22,bold=True)
c.text(60,876,'Room sizes, full outlines and offsets. The clip gives no scale or compass bearing.',18,MUTED)
c.text(60,905,'Closed-door destinations and the downstairs plan stay unassigned.',18,MUTED)
c.text(60,934,'The study–hall loop is a candidate: matching shelving is seen, but that door is not crossed.',18,MUTED)
c.line([(60,1000),(140,1000)],BLUE,5);c.text(155,985,'Observed route / opening / glazing',18)
c.line([(590,1000),(670,1000)],AMBER,3,True);c.text(685,985,'Inferred room outline or connection',18)
c.text(60,1043,'Evidence: full 1 fps pass + 2 fps rechecks at 28–43 s and 47 s–end; selected full-frame detail views.',18,MUTED)
c.save('home-floor-plan')

c=Canvas(1400,1050)
c.text(60,35,'Event hall: four walls from a single pan',36,bold=True)
c.text(60,86,'IMG_7960.MOV  •  48.16 seconds  •  Schematic footprint; no measured dimensions',21)
c.rect(190,230,900,580,fill='#f0eee5')
c.text(235,175,'B — SERVICE-OPENING WALL',24,bold=True);c.text(235,205,'Door • broad dark recess / counter • glazed doors',18,MUTED)
c.line([(250,230),(340,230)],BLUE,7);c.line([(480,230),(750,230)],INK,9);c.line([(925,230),(1030,230)],BLUE,7)
c.text(1105,350,'A — STAGE',21,bold=True);c.text(1105,386,'Large display',18);c.text(1105,416,'Plants + podium',18);c.text(1105,446,'High windows',18)
c.rect(975,300,115,385,fill='#e5d7ac',stroke=INK,dash=False);c.text(991,330,'STAGE',19,bold=True)
c.rect(1050,335,26,305,fill='#293b3b',stroke=None)
c.line([(1090,725),(1090,785)],BLUE,7);c.text(1105,735,'Door beside',17);c.text(1105,759,'stage corner',17)
c.text(60,330,'C',25,bold=True);c.text(35,365,'BRACED',18,bold=True);c.text(35,392,'WINDOW',18,bold=True);c.text(35,419,'WALL',18,bold=True)
c.line([(190,250),(190,790)],BLUE,8)
for y in [290,470,650]:c.line([(202,y),(238,y+100),(202,y+180)],INK,3)
c.text(215,838,'D — WHITEBOARD / BLIND WALL',24,bold=True);c.text(215,874,'Rolling boards in front of shaded glazing; upper glazing and mounted fixtures',18,MUTED)
c.line([(235,810),(990,810)],BLUE,6)
for x in [265,405,545,685]:c.rect(x,775,95,20,fill='#ffffff',stroke=INK,dash=False)
for x in [380,560,740]:
 for y in [355,485,615]:c.rect(x,y,110,55,fill='#d8c8a7',stroke=None)
c.text(430,280,'TABLES / WORK AREA',21,bold=True)
for y in range(340,710,55):c.rect(922,y,24,33,fill='#abbab2',stroke=None)
c.text(838,700,'Stage-facing chairs',16)
c.text(615,735,'Camera near board side',18,BLUE)
c.text(60,925,'Repeated pan: stage → service wall → braced glazing → boards → reverse → ceiling.',19)
c.text(60,959,'Adjacent rooms, upper-level uses and door destinations were not observed.',18,MUTED)
c.text(60,991,'Furniture symbols show zones, not exact counts. Dashed outline = unmeasured footprint.',18,MUTED)
c.save('hall-floor-plan')


c=Canvas(1400,820)
c.text(60,35,'Public comparison: an edited studio tour',34,bold=True)
c.text(60,85,'Apartment Therapy / Kim White  •  182.72 seconds  •  Partial spatial hypothesis',20)
c.rect(120,240,940,380,fill='#eeeee4')
c.text(235,260,'Sofa + large rattan-framed mirrors',22,bold=True)
c.line([(240,240),(660,240)],INK,7)
c.line([(120,325),(120,565)],BLUE,7);c.text(145,370,'Tall windows',18);c.text(145,401,'AC / radiator',18)
c.text(420,405,'Living space',25,bold=True);c.text(420,450,'Coffee table + rug',18)
c.line([(355,620),(670,620)],INK,7);c.text(375,570,'Fireplace + TV',22,bold=True)
c.rect(800,240,260,380,fill='#f2e8b3');c.text(825,290,'KITCHENETTE',22,bold=True);c.text(825,340,'Gold cabinets',18);c.text(825,373,'Range / refrigerator',17);c.text(825,470,'Banquette + table',18)
c.line([(690,515),(805,515)],BLUE,5);c.text(645,645,'Co-visible in wide shots at 139–144 s',18,BLUE)
c.rect(1100,170,240,210,fill='#e4eef1');c.text(1120,195,'BATHROOM',22,bold=True);c.text(1120,237,'Tub observed',18);c.text(1120,271,'Position unknown',18,AMBER);c.text(1120,310,'Separate edited shots',16)
c.text(80,703,'Bathroom connection, entrance and sleeping layout are unresolved; no continuous route is claimed.',19)
c.text(80,745,'296 sq ft appears on screen: publisher claim, not a recovered measurement.',18,MUTED)
c.save('youtube-spatial-hypothesis')
