#!/usr/bin/env python3
"""Build offline speech workers for every architecture of the application."""
import argparse
import os
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
COMMIT = '4979e04f5dcaccb36057e059bbaed8a2f5288315'
MODEL = 'ggml-base.en-q5_1.bin'
MODEL_SHA = '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f'

if os.environ.get('BOBTV_ASR_MULTILINGUAL') == '1':
    MODEL = 'ggml-base-q5_1.bin'
    MODEL_SHA = '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898'


def run(*args):
    subprocess.run([str(x) for x in args], check=True)


def prepare(app, cmake):
    cache = ROOT / 'build/client-asr'
    cache.mkdir(parents=True, exist_ok=True)
    source = cache / 'whisper.cpp'
    if not source.exists():
        run('git', 'clone', '--depth', '1', '--branch', 'v1.8.2',
            'https://github.com/ggml-org/whisper.cpp.git', source)
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == COMMIT
    run('git', '-C', source, 'diff', '--exit-code', 'HEAD')
    model = cache / MODEL
    if not model.exists():
        temporary = model.with_suffix('.download')
        urllib.request.urlretrieve('https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/' + MODEL, temporary)
        temporary.replace(model)
    assert hashlib.sha256(model.read_bytes()).hexdigest() == MODEL_SHA
    architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/BobTV')], text=True).split()
    assert architectures and set(architectures) <= {'x86_64', 'arm64'}
    outputs = []
    for cpu in architectures:
        deployment = '11.0' if cpu == 'arm64' else '10.15'
        build = cache / ('whisper-build-' + cpu)
        run(cmake, '-S', source, '-B', build, '-DCMAKE_BUILD_TYPE=Release',
            '-DCMAKE_SYSTEM_NAME=Darwin', '-DCMAKE_SYSTEM_PROCESSOR=' + cpu,
            '-DCMAKE_OSX_ARCHITECTURES=' + cpu, '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + deployment,
            '-DBUILD_SHARED_LIBS=OFF', '-DWHISPER_BUILD_EXAMPLES=OFF', '-DWHISPER_BUILD_TESTS=OFF',
            '-DGGML_METAL=OFF', '-DGGML_NATIVE=OFF', '-DGGML_OPENMP=OFF',
            '-DGGML_BLAS=ON', '-DGGML_BLAS_VENDOR=Apple',
            '-DCMAKE_CXX_FLAGS=-UACCELERATE_NEW_LAPACK -UACCELERATE_LAPACK_ILP64')
        run(cmake, '--build', build, '-j4')
        binary = cache / ('bobtv-client-asr-' + cpu)
        libraries = [build / p for p in ['src/libwhisper.a', 'ggml/src/libggml.a',
                     'ggml/src/libggml-base.a', 'ggml/src/libggml-cpu.a', 'ggml/src/ggml-blas/libggml-blas.a']]
        run('clang++', '-std=c++17', '-O2', '-arch', cpu, '-mmacosx-version-min=' + deployment,
            ROOT / 'tools/native/client_asr.cpp', '-I', source / 'include', '-I', source / 'ggml/include',
            '-I', source / 'examples', *libraries, '-framework', 'Accelerate', '-framework', 'Foundation', '-o', binary)
        outputs.append(binary)
    target = app / 'Contents/Resources/ClientASR'
    target.mkdir(parents=True, exist_ok=True)
    # A reused build directory must not select the previous QA model.
    for stale in ('ggml-base-q5_1.bin', 'ggml-base.en-q5_1.bin'):
        if stale != MODEL:
            (target / stale).unlink(missing_ok=True)
    run('lipo', '-create', *outputs, '-output', target / 'bobtv-client-asr')
    for file in (model, source / 'LICENSE', ROOT / 'tools/native/client_asr.cpp'):
        shutil.copy2(file, target / file.name)
    (target / 'receipt.json').write_text(json.dumps(dict(sourceCommit=COMMIT, modelSha256=MODEL_SHA,
        alignment='dtw', architectures=architectures,
        sourceSha256=hashlib.sha256((ROOT / 'tools/native/client_asr.cpp').read_bytes()).hexdigest()), indent=2))
    run('codesign', '--force', '--sign', '-', target / 'bobtv-client-asr')
    sdk_major = int(subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).split('.')[0])
    if sdk_major >= 26:
        native_source = ROOT / 'tools/native/client_asr_macos.swift'
        native_bins = []
        for cpu in architectures:
            binary = cache / ('bobtv-system-asr-' + cpu)
            deployment = '11.0' if cpu == 'arm64' else '10.15'
            run('xcrun', 'swiftc', '-parse-as-library', '-O', '-target',
                cpu+'-apple-macosx'+deployment, native_source, '-o', binary)
            native_bins.append(binary)
        system_worker = target / 'bobtv-system-asr'
        run('lipo', '-create', *native_bins, '-output', system_worker)
        run('codesign', '--force', '--sign', '-', system_worker)
    from prepare_client_remux import prepare as prepare_remux
    prepare_remux(app)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--cmake', default=shutil.which('cmake'))
    args = parser.parse_args()
    if not args.cmake:
        parser.error('CMake is required; specify --cmake PATH')
    prepare(args.app, args.cmake)
    run('codesign', '--force', '--deep', '--sign', '-', args.app)
