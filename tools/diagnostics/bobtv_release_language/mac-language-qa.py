import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import unicodedata

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("helper", type=Path)
args = parser.parse_args()
app = args.app.resolve()
out = args.output.resolve()
helper = str(args.helper.resolve())
out.mkdir(parents=True, exist_ok=True)
profile = out/"profile"
(profile/"Library/Preferences").mkdir(parents=True, exist_ok=True)
languages = {
    "en": "English", "zh-CN": "简体中文", "zh-TW": "繁體中文", "ja": "日本語",
    "fr": "Français", "es": "Español", "ko": "한국어",
}
ocr_codes = {
    "en": "en-US", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant", "ja": "ja-JP",
    "fr": "fr-FR", "es": "es-ES", "ko": "ko-KR",
}

env = dict(os.environ, CFFIXED_USER_HOME=str(profile))
runner = app/"Contents/MacOS/BobTV"
font_path = app/"Contents/Frameworks/App.framework/Resources/flutter_assets/fonts/MaterialIcons-Regular.otf"
catalog_path = font_path.parent.parent/"assets/i18n"

def run(*argv):
    return subprocess.check_output([str(arg) for arg in argv],text=True,timeout=55)

def window(pid):
    return json.loads(run(helper,"window",pid))

def capture(pid,name):
    info = window(pid)
    path = out/(name+".png")
    run("/usr/sbin/screencapture","-x","-o","-l",info["id"],path)
    return info["bounds"],path

def glyph(size):
    font = ImageFont.truetype(str(font_path),size)
    img = Image.new("L",(size*2,size*2))
    ImageDraw.Draw(img).text((size//2,size//2),"\ue366",font=font,anchor="mm",fill=255)
    return np.array(img.crop(img.getbbox()))

def globe(path,bounds):
    img = cv2.imread(str(path),cv2.IMREAD_GRAYSCALE)
    h,w = img.shape
    scale = w / bounds["Width"]
    roi = img[:round(130*scale),round(w*.20):]
    best = (-1,0,0)
    for size in range(round(17*scale),round(23*scale)+1):
        template=glyph(size)
        scores=cv2.matchTemplate(roi,template,cv2.TM_CCOEFF_NORMED)
        _,score,_,(x,y)=cv2.minMaxLoc(scores)
        if score > best[0]:
            best=(score,(x+round(w*.20)+template.shape[1]/2)/w,(y+template.shape[0]/2)/h)
    if best[0] < .72: raise RuntimeError(f"Globe icon match is weak: {best}")
    return best[1:]

def click(pid,bounds,x,y):
    run(helper,"click",bounds["X"]+bounds["Width"]*x,bounds["Y"]+bounds["Height"]*y,pid)
    time.sleep(.42)

def normalized(value):
    return "".join(ch for ch in unicodedata.normalize("NFKC",value).casefold() if ch.isalnum())

def recognized(path,codes):
    return json.loads(run(helper,"ocr",path,*dict.fromkeys(codes)))

def label(path,value,codes):
    desired = normalized(value)
    found = recognized(path,codes)
    return next((row for row in found if normalized(row["text"]) == desired),None)

def launch():
    logfile = (out/"app.log").open("ab")
    process=subprocess.Popen([str(runner),"-AppleLanguages","(en)"],env=env,stdout=logfile,stderr=logfile)
    logfile.close()
    return process

def stop(process):
    if process.poll() is not None: return
    process.terminate()
    try: process.wait(12)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(5)

def ready(process,name):
    until=time.monotonic()+110
    while time.monotonic()<until:
        if process.poll() is not None: raise RuntimeError(f"BobTV exited {process.returncode}")
        try:
            bounds,path=capture(process.pid,name)
            return bounds,path,globe(path,bounds)
        except (RuntimeError,subprocess.CalledProcessError,AttributeError):
            time.sleep(1)
    raise RuntimeError("No BobTV language globe was found")

def read_copy(tag,key):
    return json.loads((catalog_path/(tag+".json")).read_text())[key]

passed=[]
process=launch()
try:
    for tag,value in languages.items():
        ready(process,"ready-"+tag)
        run(helper,"activate",process.pid)
        found=None
        for attempt in range(3):
            bounds,path,(x,y)=ready(process,"before-"+tag)
            click(process.pid,bounds,x,y)
            bounds,path=capture(process.pid,"menu-"+tag)
            found=label(path,value,[ocr_codes[tag],"en-US"])
            if found: break
            english=label(path,"English",["en-US"])
            french=label(path,"Français",["fr-FR","en-US"])
            if english and french:
                spacing=(french["y"]-english["y"])/4
                found={"x":english["x"],"y":english["y"]+list(languages).index(tag)*spacing}
                break
        if not found:
            raise RuntimeError("Language choices were not visible in "+str(path))
        click(process.pid,bounds,found["x"],found["y"])
        bounds,path,_=ready(process,"active-"+tag)
        ui=read_copy(tag,"选台")
        visible=label(path,ui,[ocr_codes[tag],"en-US"])
        if not visible:
            # When the directory is not available, the selected menu's first
            # label provides an independent localized string to check.
            x,y=globe(path,bounds)
            click(process.pid,bounds,x,y)
            bounds,menu=capture(process.pid,"translated-"+tag)
            expected=read_copy(tag,"跟随系统")
            visible=label(menu,expected,[ocr_codes[tag],"en-US"])
            if not visible:
                raise RuntimeError(f"Missing translated text {ui!r} and {expected!r} for {tag}")
            click(process.pid,bounds,.07,.74)
        passed.append(tag)
    stop(process)
    process=launch()
    bounds,path,(x,y)=ready(process,"restart-ko")
    click(process.pid,bounds,x,y)
    _,menu=capture(process.pid,"restart-menu-ko")
    assert label(menu,read_copy("ko","跟随系统"),["ko-KR","en-US"]), "Korean selection did not survive restart"
    result={"passed":True,"architecture":os.uname().machine,"languages":passed,"retainedAfterRestart":"ko"}
    (out/"result.json").write_text(json.dumps(result,indent=2)+"\n")
    print(result)
finally:
    stop(process)
