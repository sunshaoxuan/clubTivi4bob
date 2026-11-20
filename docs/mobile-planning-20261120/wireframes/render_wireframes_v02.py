"""Render static planning illustrations only. No application code or runtime UI."""
from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

OUT=Path(__file__).parent
FONT='/System/Library/Fonts/STHeiti Light.ttc'
S=2
BG='#f3f3f3'; INK='#252525'; MUTED='#737373'; BORDER='#c7c7c7'
class Canvas:
 def __init__(self,w,h,bg='white'):
  self.im=Image.new('RGB',(w*S,h*S),bg); self.d=ImageDraw.Draw(self.im)
 def box(self,xy,fill='white',outline=BORDER,r=0,width=1):
  v=tuple(int(a*S) for a in xy)
  if r:self.d.rounded_rectangle(v,radius=r*S,fill=fill,outline=outline,width=width*S)
  else:self.d.rectangle(v,fill=fill,outline=outline,width=width*S)
 def text(self,x,y,t,size=16,fill=INK):
  self.d.text((x*S,y*S),t,font=ImageFont.truetype(FONT,size*S),fill=fill)
 def line(self,pts,fill=BORDER,width=1):self.d.line([(int(x*S),int(y*S)) for x,y in pts],fill=fill,width=width*S)
 def button(self,x,y,w,label,selected=False,h=48):
  self.box((x,y,x+w,y+h), '#3b3b3b' if selected else 'white', INK if selected else BORDER,8)
  font=ImageFont.truetype(FONT,15*S); tw=self.d.textlength(label,font=font)/S
  self.text(x+(w-tw)/2,y+(h-17)/2,label,15,'white' if selected else INK)
  if selected and not label.startswith(('频道','应用')):self.line([(x+8,y+24),(x+12,y+28),(x+19,y+19)],'white',2)
 def save(self,name):self.im.save(OUT/name)

def status(c,w=390):
 c.text(22,16,'9:41',14); c.text(w-118,16,'网络  电量',12,MUTED)
 c.line([(0,45),(w,45)])
def home(c,w,h):c.box((w/2-53,h-18,w/2+53,h-14),INK,INK,2)
def video(c,xy,label='视频播放区域'):
 x,y,x2,y2=xy;c.box(xy,'#dedede','#ababab');c.line([(x,y),(x2,y2)],'#c3c3c3');c.line([(x2,y),(x,y2)],'#c3c3c3')
 c.box(((x+x2)/2-95,(y+y2)/2-23,(x+x2)/2+95,(y+y2)/2+23),'#dedede','#dedede')
 c.text((x+x2)/2-77,(y+y2)/2-12,label,22)

def portrait():
 c=Canvas(390,844);status(c)
 c.text(18,64,'‹ 返回',17);c.text(137,64,'示例频道 A',18);c.text(341,64,'•••',17)
 video(c,(0,104,389,324));c.text(18,274,'直播',13)
 c.button(12,336,74,'暂停');c.button(94,336,74,'全屏');c.button(284,336,94,'频道 ↑',True)
 c.text(20,414,'正在播放',14,MUTED);c.text(20,445,'示例节目 · 自然纪录',22)
 c.text(20,482,'14:00 至 15:00',14,MUTED)
 c.line([(20,523),(370,523)])
 c.text(20,548,'接下来',14,MUTED);c.text(20,580,'15:00  示例节目 · 城市漫步',17)
 c.button(20,638,164,'节目单');c.button(204,638,164,'收藏频道')
 c.text(20,728,'播放源：用户添加的订阅',14,MUTED)
 c.text(20,758,'频道列表默认收起，按需打开',14,MUTED)
 home(c,390,844);return c

def drawer_base():
 c=portrait()
 c.box((0,324,389,843),'#fafafa',BORDER,16)
 c.box((168,333,222,337),'#999','#999',2)
 return c

def card(c,x,y,w,title,program,selected=False,h=122):
 c.box((x,y,x+w,y+h),'#ededed' if selected else 'white',INK if selected else BORDER,8,2 if selected else 1)
 c.box((x+10,y+12,x+44,y+42),'#eee',BORDER,4);c.text(x+14,y+19,'台标',10,MUTED)
 c.text(x+10,y+53,title,16);c.text(x+10,y+81,program,12,MUTED)
 if selected:c.text(x+57,y+20,'播放中',12)

def channels():
 c=drawer_base();c.text(16,355,'频道',21);c.text(76,360,'128 个',13,MUTED);c.button(314,345,60,'关闭')
 c.button(16,404,174,'搜索频道');c.button(200,404,174,'分类  2')
 for x,label,sel in [(16,'全部',True),(138,'收藏',False),(260,'最近',False)]:c.button(x,464,114,label,sel)
 c.text(16,525,'我的订阅 · 地区 A / 纪录片',13,MUTED)
 for row in range(2):
  for col in range(2):
   idx=row*2+col;card(c,16+col*184,553+row*112,174,f'示例频道 {chr(65+idx)}','当前：示例节目',idx==0,h=102)
 c.text(121,791,'上下滚动查看更多',13,MUTED)
 c.box((381,557,384,680),'#aaa','#aaa',1)
 home(c,390,844);return c

def filters():
 c=drawer_base();c.button(16,345,60,'返回');c.text(114,358,'筛选频道',21);c.button(314,345,60,'关闭')
 c.text(16,409,'来源',15);c.button(16,435,112,'全部');c.button(138,435,236,'我的订阅',True)
 c.text(16,501,'国家 / 地区',15)
 for x,t,on in [(16,'全部',False),(138,'地区 A',True),(260,'地区 B',False)]:c.button(x,528,114,t,on)
 c.text(16,594,'频道类别',15)
 for x,y,t,on in [(16,621,'全部',False),(138,621,'新闻',False),(260,621,'体育',False),(16,677,'影视',False),(138,677,'纪录片',True),(260,677,'更多',False)]:c.button(x,y,114,t,on)
 c.line([(0,746),(389,746)])
 c.button(16,759,112,'重置');c.button(138,759,236,'应用 · 24 个频道',True)
 home(c,390,844);return c

def landscape():
 c=Canvas(844,390);video(c,(0,0,843,389),'视频继续播放')
 c.text(27,20,'‹ 返回    示例频道 A',16);c.text(30,340,'暂停   全屏',16)
 # Overlay: content preserves full video geometry, left half remains visible.
 c.box((0,0,463,389),'#c5c5c5','#c5c5c5');c.text(82,161,'原视频继续播放',23);c.text(87,199,'点外侧可收起抽屉',15,MUTED)
 c.box((464,0,843,389),'#fafafa',BORDER)
 c.text(480,17,'频道',20);c.text(538,22,'128 个',12,MUTED);c.button(769,6,60,'关闭')
 c.button(478,64,105,'搜索');c.button(591,64,105,'分类  2');c.button(704,64,125,'全部 v',True)
 c.text(480,126,'我的订阅 · 地区 A / 纪录片',13,MUTED)
 for row in range(2):
  for col in range(2):
   idx=row*2+col;card(c,478+col*180,152+row*105,171,f'示例频道 {chr(65+idx)}','当前：示例节目',idx==0,h=96)
 c.box((836,157,839,261),'#aaa','#aaa',1)
 c.box((352,377,462,381),INK,INK,2)
 return c

p=portrait();d=channels();f=filters();l=landscape()
lc=Canvas(844,390);video(lc,(0,0,843,389),'横屏全屏视频')
lc.text(28,24,'‹ 返回    示例频道 A',18)
lc.button(24,314,88,'暂停');lc.button(124,314,88,'退出全屏');lc.button(716,314,104,'频道 ›',True)
lc.box((369,377,475,381),INK,INK,2)
lc.save('02a-phone-landscape-closed-v02.png')
for obj,name in [(p,'01-phone-portrait-v02.png'),(l,'02-phone-landscape-drawer-v02.png'),(d,'03-channel-drawer-v02.png'),(f,'04-category-filter-v02.png')]:obj.save(name)
b=Canvas(1760,1660,BG)
b.text(70,34,'BobTV 手机 UI/UE · 低保真布局 v0.2',36)
b.text(70,88,'iPhone / Android 手机共用结构  |  示例内容  |  仅用于布局评审，尚未实现',20,MUTED)
for x,obj,title,desc in [(80,p,'01  手机竖屏','视频 + 节目摘要，频道按需呼出'),(670,d,'03  频道抽屉','竖屏从下向上，两列纵向滚动'),(1260,f,'04  分类筛选','底部抽屉内筛选，保留上方视频')]:
 b.text(x,142,title,24);b.text(x,179,desc,17,MUTED)
 b.im.paste(obj.im,(x*S,220*S));b.box((x,220,x+390,1064),None,INK,0,2)
b.text(80,1110,'02  手机横屏 · 展示频道抽屉打开状态',24)
b.im.paste(l.im,(80*S,1160*S));b.box((80,1160,924,1550),None,INK,0,2)
b.text(1035,1165,'本轮先确认的交互',25)
for y,t in [(1222,'① 竖屏向上呼出，横屏向左呼出'),(1270,'② 单击切台，首帧成功后收起抽屉'),(1318,'③ 切台失败保留列表，方便换台'),(1366,'④ 分类点“应用”生效，筛选不切台'),(1414,'⑤ 窄屏或大字体时降为单列')]:b.text(1035,y,t,20)
b.text(80,1600,'2026-11-20  ·  灰阶仅表达区域与层级，颜色和精确尺寸待评审。',18,MUTED)
b.save('overview-v02.png')
print(OUT.resolve()/'overview-v02.png')
