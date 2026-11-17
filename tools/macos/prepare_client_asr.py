#!/usr/bin/env python3
"""Build and embed the Mac-only client ASR pilot into an isolated app bundle.
Requires CMake and Xcode. The model is an offline artifact, never an API key.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
ROOT=Path(__file__).resolve().parents[2]
COMMIT='4979e04f5dcaccb36057e059bbaed8a2f5288315'
MODEL='ggml-base.en-q5_1.bin'
MODEL_SHA='4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f'
def run(*args):subprocess.run([str(x) for x in args],check=True)
def prepare(app,cmake):
    cache=ROOT/'build/client-asr';cache.mkdir(parents=True,exist_ok=True);source=cache/'whisper.cpp';build=cache/'whisper-build'
    if not source.exists():run('git','clone','--depth','1','--branch','v1.8.2','https://github.com/ggml-org/whisper.cpp.git',source)
    assert subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()==COMMIT
    run('git','-C',source,'diff','--exit-code','HEAD')
    model=cache/MODEL
    if not model.exists():
        temporary=model.with_suffix('.download');urllib.request.urlretrieve('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/'+MODEL,temporary);temporary.replace(model)
    assert hashlib.sha256(model.read_bytes()).hexdigest()==MODEL_SHA,'model_checksum'
    run(cmake,'-S',source,'-B',build,'-DCMAKE_BUILD_TYPE=Release','-DBUILD_SHARED_LIBS=OFF','-DWHISPER_BUILD_EXAMPLES=OFF','-DWHISPER_BUILD_TESTS=OFF','-DGGML_METAL=OFF','-DGGML_NATIVE=OFF')
    run(cmake,'--build',build,'-j4')
    binary=cache/'bobtv-client-asr'
    run('clang++','-std=c++17','-O2',ROOT/'tools/native/client_asr.cpp','-I',source/'include','-I',source/'ggml/include','-I',source/'examples',build/'src/libwhisper.a',build/'ggml/src/libggml.a',build/'ggml/src/libggml-base.a',build/'ggml/src/libggml-cpu.a',build/'ggml/src/ggml-blas/libggml-blas.a','-framework','Accelerate','-framework','Foundation','-o',binary)
    target=app/'Contents/Resources/ClientASR';target.mkdir(parents=True,exist_ok=True)
    for file in (binary,model,source/'LICENSE',ROOT/'tools/native/client_asr.cpp'):shutil.copy2(file,target/file.name)
    (target/'receipt.json').write_text(json.dumps(dict(sourceCommit=COMMIT,modelSha256=MODEL_SHA,scope='Mac native client pilot',alignment='dtw',architecture=subprocess.check_output(['uname','-m'],text=True).strip()),indent=2))
    run('codesign','--force','--sign','-',target/binary.name)
    from prepare_client_remux import prepare as prepare_remux
    prepare_remux(app)
    run('codesign','--force','--deep','--sign','-',app)
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('app',type=Path);p.add_argument('--cmake',default=shutil.which('cmake'));a=p.parse_args()
    if not a.cmake:p.error('CMake is required; specify --cmake PATH')
    prepare(a.app,a.cmake)
