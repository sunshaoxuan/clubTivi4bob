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
    roi=img[:140,int(img.shape[1]*.03):]
    best=(-1,0,0)
    for size in range(17,34):
        font=ImageFont.truetype(str(font_path),size)
        glyph=Image.new("L",(size*2,size*2))
        ImageDraw.Draw(glyph).text((size//2,size//2),"\ue366",font=font,anchor="mm",fill=255)
        tmpl=np.asarray(glyph.crop(glyph.getbbox()))
        _,score,_,(x,y)=cv2.minMaxLoc(cv2.matchTemplate(roi,tmpl,cv2.TM_CCOEFF_NORMED))
        if score>best[0]:
            best=(score,int(img.shape[1]*.03)+x+tmpl.shape[1]//2,y+tmpl.shape[0]//2)
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

def menu_bounds(image, anchor, dpi):
    y = round(8 * dpi)
    height = round(400 * dpi)
    bottom = y + height
    if bottom + 6 >= image.shape[0]:
        return None
    # BobTvPalette.panel (#191c2e) converts to luminance 29.
    surface = (image == 29).astype(np.uint8)
    columns = surface[y:bottom].mean(axis=0)
    below = surface[bottom:bottom + 5].mean(axis=0)
    prefix = np.r_[0, columns.cumsum()]
    below_prefix = np.r_[0, below.cumsum()]
    best = None
    for size in (112, 168, 224, 280):
        width = round(size * dpi)
        left = np.arange(5, image.shape[1] - width - 5)
        if anchor is not None:
            left = left[(left - 9 * dpi <= anchor[0]) & (anchor[0] <= left + width + 9 * dpi)]
        if not left.size:
            continue
        right = left + width
        occupancy = (prefix[right] - prefix[left]) / width
        edges = (prefix[left] - prefix[left - 4] + prefix[right + 4] - prefix[right]) / 8
        foot = (below_prefix[right - 3] - below_prefix[left + 3]) / (width - 6)
        score = np.where(occupancy >= .60, occupancy - .25 * edges - .2 * foot, 0)
        index = score.argmax()
        if best is None or score[index] > best[0]:
            best = (score[index], int(left[index]), y, width, height)
    return best[1:] if best is not None and best[0] >= .57 else None

def switch(process, tag):
    def ready():
        rect, before = image(process, "before-" + tag)
        hwnd, _ = poll(lambda: window(process.pid))
        dpi = (user.GetDpiForWindow(hwnd) or 96) / 96
        menu = menu_bounds(before, None, dpi)
        point = None if menu else globe(before)
        return (rect, dpi, menu, point) if menu or point else None

    for attempt in range(5):
        rect, dpi, menu, point = poll(ready, 80)
        if not menu:
            click(rect, *point)
            rect, after = image(process, "menu-" + tag)
            menu = menu_bounds(after, point, dpi)
        if not menu:
            continue
        x, y, width, _ = menu
        row = languages.index(tag) + 1
        click(rect, x + width // 2, y + round((8 + 48 * (row + .5)) * dpi))
        try:
            poll(lambda: preferences() if preferences() == tag else None, 6)
        except RuntimeError:
            continue
        time.sleep(.9)
        image(process, "active-" + tag)
        print("Selected", tag, flush=True)
        return
    raise RuntimeError(f"Could not select {tag}")

def start():
    process = subprocess.Popen([str(app)], cwd=app.parent)
    hwnd, _ = poll(lambda: window(process.pid), 110)
    # A first-login window on the ARM runner can retain foreground ownership.
    user.keybd_event(0x1B, 0, 0, 0)
    user.keybd_event(0x1B, 0, 2, 0)
    user.SetWindowPos(hwnd, -1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0040)
    user.SetForegroundWindow(hwnd)
    return process

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
        "retainedAfterRestart":"ko", "setupSha256":os.environ["BOBTV_QA_SETUP_SHA256"]},indent=2)+"\n")
finally:
    stop(process)
