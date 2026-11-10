import argparse
import csv
import io
import json
import os
from pathlib import Path
import subprocess
import time
import unicodedata

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

from mac_popup_shape import popup_bounds

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
    return "".join(ch for ch in unicodedata.normalize("NFKD",value).casefold() if ch.isalnum())

def recognized(path, codes, region=None):
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
    if region:
        left, top, right, bottom = region
        image = image[top:bottom, left:right]
    else:
        image = image[round(.045 * image.shape[0]):]
    image = cv2.resize(image, None, fx=3, fy=3, interpolation=cv2.INTER_CUBIC)
    _, image = cv2.threshold(image, 145, 255, cv2.THRESH_BINARY_INV)
    models = {
        "en-US": "eng", "zh-Hans": "chi_sim", "zh-Hant": "chi_tra",
        "ja-JP": "jpn", "fr-FR": "fra", "es-ES": "spa", "ko-KR": "kor",
    }
    languages = "+".join(models[code] for code in dict.fromkeys(codes))
    result = subprocess.run(
        ["tesseract", "stdin", "stdout", "--tessdata-dir", os.environ["BOBTV_QA_TESSDATA"],
         "-l", languages, "--psm", "7" if region else "11", "-c", "tessedit_create_tsv=1"],
        input=cv2.imencode(".png", image)[1].tobytes(), capture_output=True,
        check=True, timeout=25,
    )
    output = result.stdout.decode("utf-8-sig")
    rows = csv.DictReader(io.StringIO(output), delimiter="\t")
    if not rows.fieldnames or "level" not in rows.fieldnames:
        raise RuntimeError(f"Unexpected OCR output: {output[:200]!r}; {result.stderr.decode()[:200]}")
    lines = {}
    for word in rows:
        if word["level"] == "5" and word["text"].strip():
            line = tuple(word[key] for key in ("block_num", "par_num", "line_num"))
            lines.setdefault(line, []).append(word["text"])
    return [" ".join(words) for words in lines.values()]

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

def open_menu(process, name):
    deadline = time.monotonic() + 55
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"BobTV exited {process.returncode}")
        try:
            bounds, path = capture(process.pid, name)
            screenshot = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
            height, width = screenshot.shape
            scale = width / bounds["Width"]
            geometry = popup_bounds(screenshot, scale)
            if geometry:
                return bounds, path, geometry, scale, width, height
            x, y = globe(path, bounds)
            click(process.pid, bounds, x, y)
        except (RuntimeError, subprocess.CalledProcessError, AttributeError):
            time.sleep(.7)
    raise RuntimeError(f"Language menu did not open: {name}")

def read_copy(tag, key):
    return json.loads((catalog_path / (tag + ".json")).read_text())[key]

def check_translation(process, tag, name):
    bounds, path, (x, y, w, h), scale, width, height = open_menu(process, name)
    # The first menu option is localized independently of the seven fixed labels.
    # Include the popup's left edge in the crop if its surface is partly obscured.
    left = max(0, x - round(8 * scale))
    top = y + round(8 * scale)
    right = min(width, x + w)
    bottom = y + round(56 * scale)
    observed = recognized(path, [ocr_codes[tag]], (left, top, right, bottom))
    desired = read_copy(tag, "跟随系统")
    if normalized(desired) not in {normalized(value) for value in observed}:
        raise RuntimeError(f"Expected {desired!r} after switching to {tag}, found {observed!r}")
    click(process.pid, bounds, .05, .77)

passed = []
process = launch()
try:
    for tag in ("zh-CN", "zh-TW", "ja", "fr", "es", "en", "ko"):
        index = list(languages).index(tag)
        bounds, path, (x, y, w, h), scale, width, height = open_menu(process, "menu-" + tag)
        target_x = (x + w * .50) / width
        target_y = (y + (8 + 48 * (index + 1.5)) * scale) / height
        click(process.pid, bounds, target_x, target_y)
        time.sleep(.75)
        capture(process.pid, "active-" + tag)
        check_translation(process, tag, "translated-" + tag)
        passed.append(tag)
        print("Selected and observed", tag, flush=True)
    stop(process)
    process = launch()
    check_translation(process, "ko", "restart-ko")
    result = {"passed": True, "architecture": os.uname().machine, "languages": passed,
              "retainedAfterRestart": "ko", "dmgSha256": os.environ["BOBTV_QA_DMG_SHA256"]}
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(result)
finally:
    stop(process)
