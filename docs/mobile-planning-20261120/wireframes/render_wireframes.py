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
  if selected:self.line([(x+8,y+24),(x+12,y+28),(x+19,y+19)],'white',2)
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
 c.button(12,336,74,'暂停');c.button(94,336,74,'全屏');c.button(284,336,94,'频道 ›',True)
 c.text(20,414,'正在播放',14,MUTED);c.text(20,445,'示例节目 · 自然纪录',22)
 c.text(20,482,'14:00 至 15:00',14,MUTED)
 c.line([(20,523),(370,523)])
 c.text(20,548,'接下来',14,MUTED);c.text(20,580,'15:00  示例节目 · 城市漫步',17)
 c.button(20,638,164,'节目单');c.button(204,638,164,'收藏频道')
 c.text(20,728,'播放源：用户添加的订阅',14,MUTED)
 c.text(20,758,'频道列表默认收起，按需打开',14,MUTED)
 home(c,390,844);return c

def drawer_base():
 c=portrait();c.box((0,46,31,823),'#8b8b8b','#8b8b8b')
 c.box((32,46,389,823),'#fafafa',BORDER)
 return c

def card(c,x,y,w,title,program,selected=False,h=122):
 c.box((x,y,x+w,y+h),'#ededed' if selected else 'white',INK if selected else BORDER,8,2 if selected else 1)
 c.box((x+10,y+12,x+44,y+42),'#eee',BORDER,4);c.text(x+14,y+19,'台标',10,MUTED)
 c.text(x+10,y+53,title,16);c.text(x+10,y+81,program,12,MUTED)
 if selected:c.text(x+57,y+20,'播放中',12)

def channels():
 c=drawer_base();c.text(47,63,'频道',21);c.text(106,68,'128 个',13,MUTED);c.button(319,52,58,'关闭')
 c.button(46,112,162,'搜索频道');c.button(218,112,158,'分类  2')
 c.text(47,178,'来源：我的订阅',14,MUTED);c.text(322,178,'更改',14)
 for x,label,sel in [(46,'全部',True),(158,'收藏',False),(270,'最近',False)]:c.button(x,210,104,label,sel)
 c.text(47,278,'地区 A / 纪录片',14);c.text(305,278,'清除分类',13,MUTED)
 for row in range(3):
  for col in range(2):
   idx=row*2+col;card(c,46+col*169,316+row*136,160,f'示例频道 {chr(65+idx)}','当前：示例节目',idx==0)
 c.line([(46,730),(374,730)]);c.text(113,759,'上下滚动查看更多',14,MUTED)
 c.box((382,326,385,506),'#aaa','#aaa',1)
 home(c,390,844);return c

def filters():
 c=drawer_base();c.button(45,52,58,'返回');c.text(118,65,'筛选频道',21);c.button(319,52,58,'关闭')
 c.text(47,119,'来源',16);c.button(46,150,104,'全部');c.button(158,150,218,'我的订阅',True)
 c.text(47,223,'国家 / 地区',16)
 for x,y,w,t,on in [(46,255,104,'全部',False),(158,255,104,'地区 A',True),(270,255,104,'地区 B',False),(46,311,104,'地区 C',False),(158,311,104,'未分类',False)]:c.button(x,y,w,t,on)
 c.text(47,385,'频道类别',16)
 for x,y,t,on in [(46,418,'全部',False),(158,418,'新闻',False),(270,418,'体育',False),(46,474,'影视',False),(158,474,'纪录片',True),(270,474,'少儿',False)]:c.button(x,y,104,t,on)
 c.button(46,540,328,'展开更多类别')
 c.text(47,620,'预计显示 24 个频道',16)
 c.text(47,650,'选择后点“应用”更新列表',13,MUTED)
 c.line([(32,707),(389,707)])
 c.button(46,731,104,'重置');c.button(162,731,212,'应用 · 24 个频道',True)
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
lc.save('02a-phone-landscape-closed.png')
for obj,name in [(p,'01-phone-portrait.png'),(l,'02-phone-landscape-drawer.png'),(d,'03-channel-drawer.png'),(f,'04-category-filter.png')]:obj.save(name)
b=Canvas(1760,1660,BG)
b.text(70,34,'BobTV 手机 UI/UE · 低保真布局 v0.1',36)
b.text(70,88,'iPhone / Android 手机共用结构  |  示例内容  |  仅用于布局评审，尚未实现',20,MUTED)
for x,obj,title,desc in [(80,p,'01  手机竖屏','视频 + 节目摘要，频道按需呼出'),(670,d,'03  频道抽屉','右侧覆盖，两列频道上下滚动'),(1260,f,'04  分类筛选','大按钮，抽屉内切换筛选模式')]:
 b.text(x,142,title,24);b.text(x,179,desc,17,MUTED)
 b.im.paste(obj.im,(x*S,220*S));b.box((x,220,x+390,1064),None,INK,0,2)
b.text(80,1110,'02  手机横屏 · 展示频道抽屉打开状态',24)
b.im.paste(l.im,(80*S,1160*S));b.box((80,1160,924,1550),None,INK,0,2)
b.text(1035,1165,'本轮先确认的交互',25)
for y,t in [(1222,'① 频道按钮呼出，点外侧或关闭收起'),(1270,'② 单击切台，首帧成功后收起抽屉'),(1318,'③ 切台失败保留列表，方便换台'),(1366,'④ 分类点“应用”生效，筛选不切台'),(1414,'⑤ 窄屏或大字体时降为单列')]:b.text(1035,y,t,20)
b.text(80,1600,'2026-11-20  ·  灰阶仅表达区域与层级，颜色和精确尺寸待评审。',18,MUTED)
b.save('overview-v01.png')
print(OUT.resolve()/'overview-v01.png')
