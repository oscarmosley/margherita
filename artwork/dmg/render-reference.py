# Optional development-only reference renderer; not called by packaging. Requires Pillow and Liberation Sans.
from PIL import Image, ImageDraw, ImageFont
import math
from pathlib import Path
out=Path(__file__).resolve().parent
S=2
im=Image.new('RGB',(800*S,440*S))
px=im.load()
stops=[(0,(191,56,43)),(.52,(97,36,31)),(1,(33,26,23))]
for y in range(im.height):
 for x in range(im.width):
  t=y/(im.height-1)
  lo,hi=(stops[0],stops[1]) if t<.52 else (stops[1],stops[2])
  a=(t-lo[0])/(hi[0]-lo[0])
  c=[lo[1][i]*(1-a)+hi[1][i]*a for i in range(3)]
  for cx,cy,r,col,alpha in [(390,400,460,(250,219,163),.30),(790,10,340,(69,110,77),.52)]:
   v=max(0,1-math.hypot(x/S-cx,y/S-cy)/r)*alpha
   c=[c[i]*(1-v)+col[i]*v for i in range(3)]
  px[x,y]=tuple(round(i) for i in c)
layer=Image.new('RGBA',im.size)
d=ImageDraw.Draw(layer)
def rr(box,r,fill,outline):
 d.rounded_rectangle(tuple(round(v*S) for v in box),r*S,fill,outline,width=S)
rr((92,157,708,340),32,(255,245,224,17),(255,245,224,43))
for x in (220,580):rr((x-76,174,x+76,308),26,(26,18,13,33),(255,245,224,26))
d.line([(365*S,240*S),(435*S,240*S)],fill=(250,240,217,191),width=3*S)
d.line([(420*S,225*S),(435*S,240*S),(420*S,255*S)],fill=(250,240,217,191),width=3*S)
im=Image.alpha_composite(im.convert('RGBA'),layer)
d=ImageDraw.Draw(im)
base='/usr/share/fonts/truetype/liberation/LiberationSans'
def text(s,y,size,bold=False,alpha=255):
 font=ImageFont.truetype(base+('-Bold.ttf' if bold else '-Regular.ttf'),size*S)
 d.text((400*S,y*S),s,font=font,anchor='mt',fill=(250,240,217,alpha))
text('Welcome to',45,20,alpha=199)
text('Margherita',75,54,True)
text('Drag Margherita into Applications',365,16,alpha=230)
text('VERSION 1.0.0  ·  MADE FOR YOUR MAC',401,10,alpha=122)
im.convert('RGB').save(out/'background@2x.png')
im.convert('RGB').resize((800,440),Image.Resampling.LANCZOS).save(out/'background.png')
