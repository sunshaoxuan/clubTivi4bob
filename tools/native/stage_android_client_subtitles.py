#!/usr/bin/env python3
"""Stage checksum-verified native subtitle artifacts for an isolated Android QA.

No release assets or installed apps are changed. The emitted runtime lock is
passed explicitly with BOBTV_AUDIO_RUNTIME_LOCK to the development build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile
import urllib.request
ROOT=Path(__file__).resolve().parents[2]
ABIS={'arm':'armeabi-v7a','arm64':'arm64-v8a','x64':'x86_64'}
MODEL='ggml-base.en-q5_1.bin'
SHA='4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f'
TINY='ggml-tiny.en-q5_1.bin'
TINY_SHA='c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def stage(artifacts,output,arches):
    output.mkdir(parents=True,exist_ok=True)
    lock=json.loads((ROOT/'tools/native/runtime-lock.json').read_text())
    lock['pcmSourceSha256']=digest(ROOT/'tools/native/af_bobtv_pcm.c')
    lock['android']={k:v for k,v in lock['android'].items() if k in {ABIS[a] for a in arches}}
    for arch in arches:
        abi=ABIS[arch]
        native=artifacts/f'radio-native-android-{arch}'/abi
        worker=artifacts/f'client-subtitles-android-{arch}'
        record=json.loads((native/'runtime-build.json').read_text())
        assert record['pcmSourceSha256']==lock['pcmSourceSha256']
        assert record['fftSourceSha256']==lock['fftSourceSha256']
        for name,sha in record['files'].items():assert digest(native/name)==sha
        receipt=json.loads((worker/'receipt.json').read_text())
        assert receipt['modelSha256']==SHA and receipt['architecture']==arch
        for name,sha in receipt['sourceSha256'].items():assert digest(ROOT/'tools/native'/name)==sha
        for name,sha in receipt['files'].items():assert digest(worker/name)==sha
        assert digest(worker/MODEL)==SHA
        target=ROOT/'android/app/src/main/jniLibs'/abi;target.mkdir(parents=True,exist_ok=True)
        for name in receipt['files']:(target/name).unlink(missing_ok=True)
        fast=worker/'receipt-avx2.json'
        if fast.exists():
            optimized=json.loads(fast.read_text())
            for name,sha in optimized['sourceSha256'].items():assert digest(ROOT/'tools/native'/name)==sha
            for name,sha in optimized['files'].items():
                assert digest(worker/name)==sha
                (target/name).unlink(missing_ok=True)
        else:
            (target/'libbobtv_client_asr_avx2.so').unlink(missing_ok=True)
        base_item=json.loads((ROOT/'tools/native/runtime-lock.json').read_text())['android'][abi]
        base=ROOT/'build/native-audio-runtime-cache'/base_item['filename']
        if not base.exists() or digest(base)!=base_item['sha256']:
            base.parent.mkdir(parents=True,exist_ok=True)
            temporary=base.with_suffix('.download')
            urllib.request.urlretrieve(base_item['url'],temporary)
            assert digest(temporary)==base_item['sha256']
            temporary.replace(base)
        assert digest(base)==base_item['sha256']
        record['androidHelperArchiveSha256']=base_item['sha256']
        jar=output/f'bobtv-audio-android-{abi}.jar'
        with zipfile.ZipFile(jar,'w',zipfile.ZIP_DEFLATED) as archive, zipfile.ZipFile(base) as original:
            # Keep the pinned JNI/JavaVM bridge. Only mpv and its C++ runtime
            # are replaced by the freshly compiled audio-tap build.
            for member in original.namelist():
                if member != 'META-INF/bobtv-native-runtime.json' and not member.startswith('META-INF/sources-and-licenses/') and member not in {f'lib/{abi}/{name}' for name in record['files']} and not member.startswith(f'lib/{abi}/libbobtv_client_'):
                    archive.writestr(member,original.read(member))
            for name in record['files']:archive.write(native/name,f'lib/{abi}/{name}')
            for name in receipt['files']:archive.write(worker/name,f'lib/{abi}/{name}')
            if fast.exists():
                for name in optimized['files']:
                    if name not in receipt['files']:archive.write(worker/name,f'lib/{abi}/{name}')
            archive.writestr('META-INF/bobtv-native-runtime.json',json.dumps(record))
            for f in (native/'sources-and-licenses').rglob('*'):
                if f.is_file():archive.write(f,'META-INF/sources-and-licenses/'+str(f.relative_to(native/'sources-and-licenses')))
        lock['android'][abi]=dict(filename=jar.name,sha256=digest(jar),url=jar.as_uri())
        assets=ROOT/'android/app/src/main/assets/ClientASR';assets.mkdir(parents=True,exist_ok=True)
        if not (assets/MODEL).exists() or digest(assets/MODEL)!=SHA:shutil.copy2(worker/MODEL,assets/MODEL)
        if TINY in receipt.get('models',{}):
            assert receipt['models'][TINY]==TINY_SHA and digest(worker/TINY)==TINY_SHA
            shutil.copy2(worker/TINY,assets/TINY)
        notices=assets/'sources-and-licenses'/abi;shutil.copytree(worker/'sources-and-licenses',notices,dirs_exist_ok=True)
        shutil.copy2(worker/'receipt.json',notices/'receipt.json')
    # One shared resource archive, so a universal APK contains each model once.
    models=output/'bobtv-client-subtitle-models.jar'
    with zipfile.ZipFile(models,'w',zipfile.ZIP_DEFLATED) as archive:
        for name,expected in [(MODEL,SHA),(TINY,TINY_SHA)]:
            source=assets/name
            if name==TINY and not source.exists():continue
            assert digest(source)==expected
            archive.write(source,'bobtv-client-subtitles/'+name)
    lock['clientSubtitleModels']=dict(filename=models.name,sha256=digest(models),url=models.as_uri())
    for name in [MODEL,TINY]:(assets/name).unlink(missing_ok=True)
    (output/'runtime-lock.json').write_text(json.dumps(lock,indent=2))
    print(output/'runtime-lock.json')
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--arch',choices=list(ABIS),action='append');p.add_argument('--artifacts',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args();stage(a.artifacts.resolve(),a.output.resolve(),a.arch or list(ABIS))
