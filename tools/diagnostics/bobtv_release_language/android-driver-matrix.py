import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time

root=Path(__file__).resolve().parent
adb=[os.environ.get("BOBTV_QA_ADB","adb"),"-s",os.environ.get("BOBTV_QA_SERIAL","emulator-5568")]
package="com.briconbric.bobtv"
activity=package+"/io.github.clubanderson.clubtivi.MainActivity"
driver="com.briconbric.bobtv.qai18n/.LanguageDriver"
catalogs={p.stem:json.loads(p.read_text()) for p in (root/"source/assets/i18n").glob("*.json")}
tags={"en":"English","zh-CN":"简体中文","zh-TW":"繁體中文","ja":"日本語","fr":"Français","es":"Español","ko":"한국어"}

def run(*args,timeout=140):
    completed=subprocess.run([*adb,*args],text=True,timeout=timeout,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if completed.returncode:
        raise RuntimeError(f"ADB failed ({completed.returncode}): {args!r}\n{completed.stdout}")
    return completed.stdout

def launch():
    output=run("shell","am","start","-W","-n",activity,timeout=100)
    assert "Error" not in output,output

def exercise(operations,destination):
    shell="am instrument -w -e steps "+shlex.quote("|".join(operations))+" "+driver
    output=run("shell",shell,timeout=300)
    destination.write_text(output)
    assert "driverError=" not in output and "INSTRUMENTATION_CODE: -1" in output,output
    assert "matched="+"|".join(operations) in output,output

def switch_operations(current,tag):
    return ["+"+catalogs[current]["语言"],"+"+tags[tag],"!"+catalogs[tag]["语言"]]

assert run("shell","getprop","ro.kernel.qemu").strip()=="1"
if "success" not in run("install","--no-incremental","-r",str(root/"qa-android-driver/driver.apk")).lower():
    raise RuntimeError("Cannot install the independent UI automation driver")
for arch,abi in (("x64","x86_64"),("arm64","arm64-v8a"),("arm","armeabi-v7a")):
    dest=root/("android-qa-"+arch)
    dest.mkdir(exist_ok=True)
    if (dest/"result.json").is_file(): continue
    if ("package:"+package) in run("shell","pm","list","packages",package).splitlines():
        assert "Success" in run("uninstall",package)
    path=root/"packages"/f"BobTV-1.1.19+114-android-{arch}.apk"
    print("Installing "+path.name,flush=True)
    assert "Success" in run("install","--no-incremental","-r",str(path),timeout=220)
    info=run("shell","dumpsys","package",package)
    selected=re.search(r"primaryCpuAbi=(\S+)",info)[1]
    assert selected==abi,info
    launch()
    current="en"
    for tag in tags:
        print(arch,tag,flush=True)
        exercise(switch_operations(current,tag),dest/(tag+".log"))
        current=tag
    run("shell","am","force-stop",package)
    launch()
    exercise(["!"+catalogs["ko"]["语言"],"+"+catalogs["ko"]["语言"],
              "+"+catalogs["ko"]["跟随系统"],"!"+catalogs["en"]["语言"]],dest/"restart.log")
    result={"passed":True,"version":"1.1.19+114","abi":selected,
            "systemAbis":run("shell","getprop","ro.product.cpu.abilist").strip(),
            "nativeBridge":run("shell","getprop","ro.dalvik.vm.native.bridge").strip(),
            "apk":path.name,"sha256":hashlib.file_digest(path.open("rb"),"sha256").hexdigest(),
            "languages":list(tags),"retainedAfterRestart":"ko","followSystem":"en"}
    (dest/"result.json").write_text(json.dumps(result,indent=2)+"\n")
    print(result,flush=True)
