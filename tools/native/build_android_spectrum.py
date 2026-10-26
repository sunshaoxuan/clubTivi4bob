#!/usr/bin/env python3
"""Rebuild media-kit's pinned Android runtime with the same pass-through FFT.

Run on a Linux Android NDK build host. Only the requested architecture is built.
No installed application or shared SDK package is modified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = '1ecf5100ec0f75e1d0630f48851b85769c92eed2'
NDK = '28.2.13676358'
REPOS = {
    'mbedtls': ('Mbed-TLS/mbedtls', 'v3.4.0'),
    'dav1d': ('videolan/dav1d', '1.2.0'),
    'libxml2': ('GNOME/libxml2', 'v2.10.3'),
    'freetype': ('freetype/freetype', 'VER-2-13-0'),
    'fribidi': ('fribidi/fribidi', 'v1.0.12'),
    'harfbuzz': ('harfbuzz/harfbuzz', '7.2.0'),
    'libass': ('libass/libass', '0.17.1'),
    'ffmpeg': ('FFmpeg/FFmpeg', 'n6.0'),
    'mpv': ('mpv-player/mpv', '78d43740f52db817d98bcf24fb30a76ab6fa13ff'),
}
ABIS = {'arm': ('armv7l', 'armeabi-v7a', 'arm-linux-androideabi'),
        'arm64': ('arm64', 'arm64-v8a', 'aarch64-linux-android'),
        'x64': ('x86_64', 'x86_64', 'x86_64-linux-android')}


def run(*args, cwd=None, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def checkout(path, repo, ref):
    if not path.exists():
        path.mkdir(parents=True)
        run('git', 'init', path)
        run('git', 'remote', 'add', 'origin', f'https://github.com/{repo}.git', cwd=path)
        run('git', 'fetch', '--depth=1', 'origin', ref, cwd=path)
        run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=path)


def patch_ffmpeg(source):
    shutil.copy2(ROOT / 'tools/native/af_bobtv_spectrum.c', source / 'libavfilter/af_bobtv_spectrum.c')
    registry = source / 'libavfilter/allfilters.c'
    text = registry.read_text()
    if 'ff_af_bobtv_spectrum;' not in text:
        registry.write_text(text.replace('extern const AVFilter ff_af_astats;',
            'extern const AVFilter ff_af_astats;\nextern const AVFilter ff_af_bobtv_spectrum;'))
    makefile = source / 'libavfilter/Makefile'
    if 'CONFIG_BOBTV_SPECTRUM_FILTER' not in makefile.read_text():
        with makefile.open('a') as output:
            output.write('\nOBJS-$(CONFIG_BOBTV_SPECTRUM_FILTER) += af_bobtv_spectrum.o\n')


def build(arch, cache, output):
    upstream = cache / 'upstream'
    checkout(upstream, 'media-kit/libmpv-android-video-build', UPSTREAM)
    scripts = upstream / 'buildscripts'
    for name, (repo, ref) in REPOS.items():
        checkout(scripts / 'deps' / name, repo, ref)
    # Apply upstream's exact demuxer/JNI fixes before adding the FFT filter.
    run('bash', 'patch.sh', cwd=scripts)
    patch_ffmpeg(scripts / 'deps/ffmpeg')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
    sdk_link = scripts / 'sdk/android-sdk-linux'
    sdk_link.parent.mkdir(exist_ok=True)
    if not sdk_link.exists(): sdk_link.symlink_to(sdk, target_is_directory=True)
    if not (sdk / 'ndk' / NDK).is_dir():
        raise RuntimeError(f'Install Android NDK {NDK} in the build host SDK first')
    depinfo = scripts / 'include/depinfo.sh'
    depinfo.write_text(depinfo.read_text().replace('25.2.9519653', NDK))
    flavor = (scripts / 'flavors/default.sh').read_text()
    flavor = flavor.replace('--enable-filter=equalizer', '--enable-filter=equalizer,bobtv_spectrum')
    (scripts / 'scripts/ffmpeg.sh').write_text(flavor)
    # Avoid changing the shared SDK or launching helper applications.
    env = {**os.environ, 'cores': '4'}
    upstream_arch, abi, triple = ABIS[arch]
    run('bash', 'build.sh', '--arch', upstream_arch, cwd=scripts, env=env)
    runtime = scripts / 'prefix' / abi / 'lib/libmpv.so'
    if not runtime.is_file(): raise RuntimeError(f'Missing built runtime: {runtime}')
    toolchain = sdk / 'ndk' / NDK / 'toolchains/llvm/prebuilt/linux-x86_64'
    destination = output / abi
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(runtime, destination / 'libmpv.so')
    run(toolchain / 'bin/llvm-strip', '--strip-all', destination / 'libmpv.so')
    shutil.copy2(toolchain / 'sysroot/usr/lib' / triple / 'libc++_shared.so', destination / 'libc++_shared.so')
    strings = subprocess.check_output([str(toolchain / 'bin/llvm-strings'), str(destination / 'libmpv.so')], text=True)
    if 'bobtv_spectrum' not in strings: raise RuntimeError('The packaged runtime omitted the FFT filter')
    commits = {name: subprocess.check_output(['git', '-C', str(scripts / 'deps' / name), 'rev-parse', 'HEAD'], text=True).strip() for name in REPOS}
    record = {'architecture': abi, 'upstream': UPSTREAM, 'ndk': NDK, 'dependencies': commits,
              'fftSourceSha256': hashlib.sha256((ROOT / 'tools/native/af_bobtv_spectrum.c').read_bytes()).hexdigest(),
              'files': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in destination.glob('*.so')}}
    (destination / 'runtime-build.json').write_text(json.dumps(record, indent=2))
    notices = destination / 'sources-and-licenses'
    notices.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'tools/native/af_bobtv_spectrum.c', notices)
    shutil.copy2(Path(__file__), notices)
    for name in REPOS:
        for pattern in ('COPYING*', 'LICENSE*'):
            for file in (scripts / 'deps' / name).glob(pattern):
                if file.is_file(): shutil.copy2(file, notices / (name + '-' + file.name))
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=ABIS, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.arch, args.cache.resolve(), args.output.resolve())
