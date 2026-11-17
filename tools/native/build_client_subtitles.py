#!/usr/bin/env python3
"""Build isolated offline subtitle workers for Windows and Android.

Uses the same pinned whisper.cpp/model and decoder-free FFmpeg as the Mac pilot.
Native helpers receive loopback HLS only. HTTPS/keys are fetched once by Dart.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
WHISPER = '4979e04f5dcaccb36057e059bbaed8a2f5288315'
MODEL = 'ggml-base.en-q5_1.bin'
MODEL_SHA = '4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f'
FLAGS = ['--disable-everything', '--disable-autodetect', '--disable-programs', '--disable-doc',
         '--disable-avdevice', '--disable-avfilter', '--disable-swscale', '--disable-swresample',
         '--disable-postproc', '--enable-static', '--disable-shared', '--enable-avformat',
         '--enable-avcodec', '--enable-avutil', '--enable-protocol=file,http,tcp,crypto,pipe',
         '--enable-demuxer=hls,mpegts', '--enable-muxer=mpegts', '--enable-parser=aac,h264',
         '--enable-bsf=h264_mp4toannexb,extract_extradata,aac_adtstoasc', '--enable-network', '--disable-x86asm']


def run(*args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def checkout(path, repo, ref):
    if not path.exists():
        run('git', 'clone', '--depth', '1', '--branch', ref, f'https://github.com/{repo}.git', path)
    run('git', '-C', path, 'diff', '--exit-code', 'HEAD')


def build(args):
    cache = args.cache.resolve(); cache.mkdir(parents=True, exist_ok=True)
    source = cache / 'whisper.cpp'; checkout(source, 'ggml-org/whisper.cpp', 'v1.8.2')
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == WHISPER
    ffmpeg = cache / 'ffmpeg'; checkout(ffmpeg, 'FFmpeg/FFmpeg', 'n6.0')
    ffcommit = subprocess.check_output(['git', '-C', str(ffmpeg), 'rev-parse', 'HEAD'], text=True).strip()
    model = cache / MODEL
    if not model.exists():
        temp = model.with_suffix('.download')
        urllib.request.urlretrieve('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/' + MODEL, temp)
        temp.replace(model)
    assert hashlib.sha256(model.read_bytes()).hexdigest() == MODEL_SHA
    build = cache / f'{args.platform}-{args.arch}'; build.mkdir(exist_ok=True)
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    cmake_flags = ['-DCMAKE_BUILD_TYPE=Release', '-DBUILD_SHARED_LIBS=OFF', '-DWHISPER_BUILD_EXAMPLES=OFF',
                   '-DWHISPER_BUILD_TESTS=OFF', '-DGGML_NATIVE=OFF', '-DGGML_OPENMP=OFF', '-DGGML_BLAS=OFF',
                   '-DGGML_METAL=OFF', '-DGGML_VULKAN=OFF', '-DGGML_CPU_ALL_VARIANTS=OFF']
    extra_link = ['-lm']
    if args.platform == 'android':
        sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
        ndk = sdk / 'ndk/28.2.13676358'
        host = 'darwin-x86_64' if os.uname().sysname == 'Darwin' else 'linux-x86_64'
        toolchain = ndk / 'toolchains/llvm/prebuilt' / host
        abi, triple, ffarch = {'arm': ('armeabi-v7a', 'armv7a-linux-androideabi', 'arm'),
                              'arm64': ('arm64-v8a', 'aarch64-linux-android', 'aarch64'),
                              'x64': ('x86_64', 'x86_64-linux-android', 'x86_64')}[args.arch]
        cc = toolchain / 'bin' / f'{triple}24-clang'; cxx = Path(str(cc) + '++')
        ar = toolchain / 'bin/llvm-ar'; ranlib = toolchain / 'bin/llvm-ranlib'
        cmake_flags += [f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',
                        f'-DANDROID_ABI={abi}', '-DANDROID_PLATFORM=24', '-DANDROID_STL=c++_static',
                        '-DCMAKE_EXE_LINKER_FLAGS=-Wl,-z,max-page-size=16384']
        cross = ['--target-os=android', '--enable-cross-compile', f'--arch={ffarch}',
                 '--extra-cflags=-fPIC', '--extra-ldflags=-Wl,-z,max-page-size=16384']
        extra_link += ['-ldl', '-llog', '-static-libstdc++', '-Wl,-z,max-page-size=16384']
        names = ['libbobtv_client_asr.so', 'libbobtv_client_remux.so']
    else:
        if not args.toolchain: raise RuntimeError('--toolchain must point to the pinned LLVM-mingw directory')
        toolchain = args.toolchain.resolve()
        triple, ffarch = ('x86_64-w64-mingw32', 'x86_64') if args.arch == 'x64' else ('aarch64-w64-mingw32', 'aarch64')
        cc = toolchain / 'bin' / f'{triple}-clang'; cxx = toolchain / 'bin' / f'{triple}-clang++'
        ar = toolchain / 'bin/llvm-ar'; ranlib = toolchain / 'bin/llvm-ranlib'
        cmake_flags += ['-DCMAKE_SYSTEM_NAME=Windows', f'-DCMAKE_SYSTEM_PROCESSOR={ffarch}',
                        f'-DCMAKE_C_COMPILER={cc}', f'-DCMAKE_CXX_COMPILER={cxx}',
                        f'-DCMAKE_RC_COMPILER={toolchain}/bin/{triple}-windres', '-DCMAKE_EXE_LINKER_FLAGS=-static']
        cross = ['--target-os=mingw32', '--enable-cross-compile', f'--arch={ffarch}']
        extra_link += ['-static', '-lws2_32', '-lsecur32', '-lbcrypt']
        names = ['bobtv-client-asr.exe', 'bobtv-client-remux.exe']
    if args.cpu == 'avx2':
        if (args.platform,args.arch) != ('windows','x64'): raise RuntimeError('AVX2 worker requires Windows x64')
        cmake_flags += [f'-DGGML_{flag}=ON' for flag in ['SSE42','AVX','AVX2','F16C','FMA','BMI2']]
        names[0]='bobtv-client-asr-avx2.exe'
    whisper_build = build / ('whisper-avx2' if args.cpu == 'avx2' else 'whisper')
    run(args.cmake, '-S', source, '-B', whisper_build, '-G', 'Ninja', *cmake_flags)
    run(args.cmake, '--build', whisper_build, '-j4')
    libraries = [whisper_build / p for p in ['src/libwhisper.a', 'ggml/src/libggml.a',
                 'ggml/src/libggml-base.a', 'ggml/src/libggml-cpu.a']]
    libraries = [p if p.exists() else p.with_name(p.name.removeprefix('lib')) for p in libraries]
    run(cxx, '-std=c++17', '-O2', ROOT / 'tools/native/client_asr.cpp', '-I', source / 'include',
        '-I', source / 'ggml/include', '-I', source / 'examples', *libraries, '-pthread', *extra_link,
        '-o', output / names[0])
    fb = build / 'ffmpeg'; fb.mkdir(exist_ok=True)
    flags = [*FLAGS, *cross, f'--cc={cc}', f'--cxx={cxx}', f'--ar={ar}', f'--ranlib={ranlib}']
    marker = fb / 'configuration.json'
    if not marker.exists() or json.loads(marker.read_text()) != flags:
        run(ffmpeg / 'configure', *flags, cwd=fb); marker.write_text(json.dumps(flags))
    run('make', '-j4', cwd=fb)
    import re
    assert not re.search(r'#define CONFIG_[A-Z0-9_]+_(?:DECODER|ENCODER) 1', (fb / 'config_components.h').read_text())
    run(cxx, '-std=c++17', '-O2', ROOT / 'tools/native/client_remux.cpp', '-idirafter', fb, '-idirafter', ffmpeg,
        fb / 'libavformat/libavformat.a', fb / 'libavcodec/libavcodec.a', fb / 'libavutil/libavutil.a',
        '-pthread', *extra_link, '-o', output / names[1])
    shutil.copy2(model, output / MODEL)
    notices = output / 'sources-and-licenses'; notices.mkdir(exist_ok=True)
    for file in [source / 'LICENSE', ffmpeg / 'COPYING.LGPLv2.1', ROOT / 'tools/native/client_asr.cpp',
                 ROOT / 'tools/native/client_remux.cpp', Path(__file__)]: shutil.copy2(file, notices)
    receipt = dict(platform=args.platform, architecture=args.arch, whisperCommit=WHISPER, ffmpegCommit=ffcommit,
                   modelSha256=MODEL_SHA, alignment='dtw', decodersEnabled=False, encodersEnabled=False,
                   files={name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in names},
                   ffmpegFlags=flags)
    (output / ('receipt-avx2.json' if args.cpu == 'avx2' else 'receipt.json')).write_text(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--platform', choices=['windows', 'android'], required=True)
    p.add_argument('--arch', choices=['arm', 'arm64', 'x64'], required=True)
    p.add_argument('--cache', type=Path, required=True); p.add_argument('--output', type=Path, required=True)
    p.add_argument('--cpu',choices=['baseline','avx2'],default='baseline')
    p.add_argument('--toolchain', type=Path); p.add_argument('--cmake', default='cmake')
    build(p.parse_args())
