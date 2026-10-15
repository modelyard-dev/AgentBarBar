#!/usr/bin/env python3
"""Create the installation artwork and Finder metadata on the mounted DMG."""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from ds_store import DSStore
from mac_alias import Alias

parser=argparse.ArgumentParser()
parser.add_argument('volume',type=Path)
parser.add_argument('--version',required=True)
parser.add_argument('--preview',type=Path,required=True)
args=parser.parse_args()
volume=args.volume
font='/System/Library/Fonts/Hiragino Sans GB.ttc'
def artwork(scale):
    image=Image.new('RGB',(720*scale,520*scale),'#f4f7f6')
    draw=ImageDraw.Draw(image)
    def text(value,y,size,color):
        face=ImageFont.truetype(font,size*scale)
        width=draw.textlength(value,font=face)
        draw.text(((720*scale-width)/2,y*scale),value,font=face,fill=color)
    text('AgentBarBar',35,27,'#253c34')
    text('让 AI 用量一目了然',78,15,'#71837a')
    text('Your AI usage, at a glance',103,13,'#71837a')
    for center in [190,530]:
        draw.rounded_rectangle(tuple(v*scale for v in (center-84,145,center+84,315)),radius=25*scale,fill='#ffffff',outline='#e1e9e4',width=scale)
    draw.line(tuple(v*scale for v in (320,215,400,215)),fill='#5e927b',width=4*scale)
    draw.line(tuple(v*scale for v in (385,201,400,215,385,229)),fill='#5e927b',width=4*scale)
    text('拖到右侧“应用程序”即可安装',339,17,'#344d42')
    text('Drag AgentBarBar to Applications to install',368,14,'#344d42')
    text('打开后，点击菜单栏图标查看用量',407,12,'#78877f')
    text('Open the app, then click its menu bar icon to view usage',430,12,'#78877f')
    return image
background=volume/'.background';background.mkdir(exist_ok=True)
low=background/'install.png';high=background/'install@2x.png'
artwork(1).save(low);artwork(2).save(high)
import subprocess
subprocess.run(['tiffutil','-cathidpicheck',str(low),str(high),'-out',str(background/'install.tiff')],check=True,capture_output=True)
low.unlink();high.unlink()
args.preview.parent.mkdir(parents=True,exist_ok=True)
artwork(2).save(args.preview)
root=Path(__file__).resolve().parent.parent
alias=Alias.for_file(str(background/'install.tiff')).to_bytes()
with DSStore.open(str(volume/'.DS_Store'),'w+') as store:
    store['.']['bwsp']={'ContainerShowSidebar':False,'PreviewPaneVisibility':False,'ShowTabView':False,'ShowStatusBar':False,'WindowBounds':'{{160, 120}, {720, 520}}','ShowToolbar':False,'ShowPathbar':False,'ShowSidebar':False,'SidebarWidth':0}
    store['.']['icvp']={'scrollPositionX':0.0,'scrollPositionY':0.0,'backgroundColorRed':1.0,'backgroundColorGreen':1.0,'backgroundColorBlue':1.0,'backgroundType':2,'backgroundImageAlias':alias,'iconSize':88.0,'textSize':13.0,'gridSpacing':100.0,'gridOffsetX':0.0,'gridOffsetY':0.0,'viewOptionsVersion':1,'arrangeBy':'none','showIconPreview':True,'showItemInfo':False,'labelOnBottom':True}
    store['.']['vSrn']=('long',1)
    store['.']['icvl']=('type',b'icnv')
    store['AgentBarBar.app']['Iloc']=(190,215)
    store['Applications 应用程序']['Iloc']=(530,215)
# Keep detailed instructions available but out of the installation layout.
guide=volume/'安装说明.txt'
if guide.exists():guide.rename(volume/'.安装说明.txt')
# The metadata must refer to this distribution volume, never to a build folder.
blob=(volume/'.DS_Store').read_bytes()
for private in [str(Path.home()).encode(),str(root).encode()]:
    if private in blob:raise SystemExit('Private path in Finder metadata')
print('Finder layout: 720 × 520; icon positions and background verified')
