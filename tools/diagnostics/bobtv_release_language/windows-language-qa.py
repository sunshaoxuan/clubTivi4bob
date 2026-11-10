"""Run the exact packaged Windows application on a clean interactive runner."""
import ctypes as ct
from ctypes import wintypes as wt
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageGrab

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
font_path = app.parent/"data/flutter_assets/fonts/MaterialIcons-Regular.otf"
support = Path(os.environ["APPDATA"])
user = ct.windll.user32
user.SetProcessDPIAware()
languages = ["en", "zh-CN", "zh-TW", "ja", "fr", "es", "ko"]

def poll(fn, timeout=45):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        result=fn()
        if result is not None: return result
        time.sleep(.33)
    raise RuntimeError(f"Timed out waiting for {fn!r}")

def window(pid):
    found=[]
    handler=ct.WINFUNCTYPE(wt.BOOL,wt.HWND,wt.LPARAM)
    def collect(hwnd,_):
        ident=wt.DWORD()
        user.GetWindowThreadProcessId(hwnd,ct.byref(ident))
        if pid==ident.value and user.IsWindowVisible(hwnd):
            rect=wt.RECT()
            user.GetClientRect(hwnd,ct.byref(rect))
            if rect.right>=500 and rect.bottom>=400:
                origin=wt.POINT()
                user.ClientToScreen(hwnd,ct.byref(origin))
                found.append((hwnd,(origin.x,origin.y,origin.x+rect.right,origin.y+rect.bottom)))
        return True
    user.EnumWindows(handler(collect),0)
    return found[0] if found else None

def image(process,name):
    hwnd,rect=poll(lambda:window(process.pid))
    user.SetForegroundWindow(hwnd)
    time.sleep(.25)
    shot=ImageGrab.grab(bbox=rect)
    shot.save(out/(name+".png"))
    return rect, np.asarray(shot.convert("L"))

def globe(img):
    roi=img[:140,int(img.shape[1]*.22):]
    best=(-1,0,0)
    for size in range(17,34):
        font=ImageFont.truetype(str(font_path),size)
        glyph=Image.new("L",(size*2,size*2))
        ImageDraw.Draw(glyph).text((size//2,size//2),"\ue366",font=font,anchor="mm",fill=255)
        tmpl=np.asarray(glyph.crop(glyph.getbbox()))
        _,score,_,(x,y)=cv2.minMaxLoc(cv2.matchTemplate(roi,tmpl,cv2.TM_CCOEFF_NORMED))
        if score>best[0]:
            best=(score,int(img.shape[1]*.22)+x+tmpl.shape[1]//2,y+tmpl.shape[0]//2)
    return best[1:] if best[0]>=.73 else None

def click(rect,x,y):
    assert 0<=x<rect[2]-rect[0] and 0<=y<rect[3]-rect[1]
    user.SetCursorPos(rect[0]+x,rect[1]+y)
    time.sleep(.13)
    user.mouse_event(2,0,0,0,0)
    time.sleep(.05)
    user.mouse_event(4,0,0,0,0)
    time.sleep(.5)

def preferences():
    for path in support.glob("BobTV*/BobTV*/shared_preferences.json"):
        try:
            data=json.loads(path.read_text(encoding="utf-8-sig"))
            if "flutter.bobtv_app_language" in data:
                return data["flutter.bobtv_app_language"]
        except (OSError,ValueError): pass
    return None

def menu_bounds(before,after,anchor,dpi):
    assert before.shape==after.shape
    diff=(cv2.absdiff(before,after)>3).astype(np.uint8)
    joined=cv2.morphologyEx(diff,cv2.MORPH_CLOSE,np.ones((9,9),np.uint8))
    n,_,stats,_=cv2.connectedComponentsWithStats(joined)
    candidates=[]
    for x,y,w,h,area in stats[1:]:
        widths=(112,168,224,280)
        if (any(abs(w-size*dpi)<=7*dpi for size in widths)
            and abs(h-400*dpi)<=12*dpi and area>=w*h*.50
            and x-8*dpi<=anchor[0]<=x+w+8*dpi and y<=anchor[1]+16*dpi):
            candidates.append((int(area),int(x),int(y),int(w),int(h)))
    if not candidates: raise RuntimeError("Language popup was not detected")
    return max(candidates)[1:]

def switch(process,tag):
    def ready():
        rect,before=image(process,"before-"+tag)
        p=globe(before)
        return (rect,before,p) if p else None
    for attempt in range(5):
        rect,before,(x,y)=poll(ready,100)
        click(rect,x,y)
        rect,after=image(process,"menu-"+tag)
        try:
            hwnd,_=poll(lambda:window(process.pid))
            dpi=user.GetDpiForWindow(hwnd)/96
            x,y,w,h=menu_bounds(before,after,(x,y),dpi)
            break
        except RuntimeError:
            if attempt == 4: raise
            time.sleep(.8)
    row=languages.index(tag)+1
    click(rect,x+w//2,y+int(h*(row+.5)/8))
    assert poll(lambda: preferences() if preferences()==tag else None,12)==tag
    image(process,"active-"+tag)

def start():
    return subprocess.Popen([str(app)],cwd=app.parent)

def stop(process):
    if process.poll() is None:
        process.terminate()
        process.wait(12)

process=start()
passed=[]
try:
    for tag in languages:
        switch(process,tag)
        passed.append(tag)
    stop(process)
    process=start()
    poll(lambda:window(process.pid))
    time.sleep(7)
    assert preferences()=="ko"
    image(process,"restart-ko")
    (out/"result.json").write_text(json.dumps({"passed":True,"languages":passed,
        "retainedAfterRestart":"ko"},indent=2)+"\n")
finally:
    stop(process)
