#!/usr/bin/env python3
"""Assemble pinned MSYS2 libmpv runtimes and rebuild their FFT-enabled avfilter.

This isolates native dependencies in a build cache and never installs a system
package or alters an installed BobTV. Each package is checked against its repo
SHA-256; the complete input lock and corresponding source URLs are recorded.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request
import zstandard
import pefile

ROOT = Path(__file__).resolve().parents[2]
LLVM_NAME = 'llvm-mingw-20261020-ucrt-macos-universal'
LLVM_SHA256 = 'e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e'


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def fetch(url, path, sha=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and (sha is None or digest(path) == sha): return path
    temporary = path.with_suffix(path.suffix + '.partial')
    urllib.request.urlretrieve(url, temporary)
    if sha and digest(temporary) != sha: raise RuntimeError('Checksum mismatch: ' + path.name)
    temporary.replace(path)
    return path


def tar_open(path):
    data = path.read_bytes()
    if data[:4] == b'\x28\xb5\x2f\xfd':
        with zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data)) as stream:
            data = stream.read()
    return tarfile.open(fileobj=io.BytesIO(data))


def database(path):
    result = {}
    with tar_open(path) as tar:
        for member in tar:
            if not member.name.endswith('/desc'): continue
            text = tar.extractfile(member).read().decode()
            fields = {}
            for entry in text.split('\n\n'):
                lines = entry.strip().splitlines()
                if lines and lines[0].startswith('%'):
                    fields[lines[0].strip('%')] = lines[1:]
            name = fields['NAME'][0]
            result[name] = fields
    return result


def run(*args, cwd=None, env=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True)


def build(arch, cache, output):
    repo, prefix, triple = ('ucrt64', 'mingw-w64-ucrt-x86_64-', 'x86_64-w64-mingw32') if arch == 'x64' else ('clangarm64', 'mingw-w64-clang-aarch64-', 'aarch64-w64-mingw32')
    base = f'https://repo.msys2.org/mingw/{repo}/'
    db = database(fetch(base + repo + '.db', cache / (repo + '.db')))
    providers = {re.split(r'[<>=]', provided)[0]: name for name, item in db.items() for provided in item.get('PROVIDES', [])}
    pending = [prefix + 'mpv']; selected = {}
    while pending:
        name = re.split(r'[<>=]', pending.pop())[0]
        if not name.startswith(prefix): continue  # console-only MSYS helpers are not DLL dependencies
        name = name if name in db else providers.get(name, name)
        if name in selected: continue
        if name not in db: raise RuntimeError('Missing native dependency: ' + name)
        selected[name] = db[name]
        pending.extend(db[name].get('DEPENDS', []))
    extracted = cache / ('msys-' + repo)
    extracted.mkdir(exist_ok=True)
    def download(item):
        name, fields = item
        return fetch(base + fields['FILENAME'][0], cache / 'packages' / fields['FILENAME'][0], fields['SHA256SUM'][0])
    with ThreadPoolExecutor(max_workers=8) as pool:
        packages = list(pool.map(download, sorted(selected.items())))
    for package in packages:
        with tar_open(package) as tar: tar.extractall(extracted)
    sysroot = extracted / repo
    ffversion = selected[prefix + 'ffmpeg']['VERSION'][0].split('-')[0]
    source_tar = fetch(f'https://ffmpeg.org/releases/ffmpeg-{ffversion}.tar.xz', cache / f'ffmpeg-{ffversion}.tar.xz')
    source = cache / f'ffmpeg-{ffversion}'
    if not source.exists():
        with tar_open(source_tar) as tar: tar.extractall(cache)
    shutil.copy2(ROOT / 'tools/native/af_bobtv_spectrum.c', source / 'libavfilter/af_bobtv_spectrum.c')
    registry = source / 'libavfilter/allfilters.c'
    text = registry.read_text()
    if 'ff_af_bobtv_spectrum;' not in text:
        match = re.search(r'extern const (?:FFFilter|AVFilter) ff_af_astats;', text)
        if not match: raise RuntimeError('Review this FFmpeg registry version')
        registry.write_text(text.replace(match.group(), match.group() + '\n' + match.group().replace('ff_af_astats', 'ff_af_bobtv_spectrum')))
    makefile = source / 'libavfilter/Makefile'
    if 'CONFIG_BOBTV_SPECTRUM_FILTER' not in makefile.read_text():
        with makefile.open('a') as target: target.write('\nOBJS-$(CONFIG_BOBTV_SPECTRUM_FILTER) += af_bobtv_spectrum.o\n')
    llvm_archive = fetch(f'https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/{LLVM_NAME}.tar.xz', cache / (LLVM_NAME + '.tar.xz'), LLVM_SHA256)
    toolchain = cache / LLVM_NAME
    if not toolchain.exists():
        with tar_open(llvm_archive) as tar: tar.extractall(cache)
    binary_dir = cache / ('avfilter-' + arch)
    binary_dir.mkdir(exist_ok=True)
    install = binary_dir / 'install'
    clang = toolchain / 'bin' / (triple + '-clang')
    # No codec/format library is replaced. The rebuilt filter links against the
    # same-version public avutil/swscale/swresample ABI in the MSYS2 runtime.
    flags = [str(source / 'configure'), '--disable-everything', '--disable-autodetect',
             '--disable-programs', '--disable-doc', '--disable-avdevice', '--disable-avformat',
             '--disable-avcodec', '--disable-postproc', '--disable-x86asm', '--enable-shared',
             '--disable-static', '--enable-avfilter', '--enable-swresample', '--enable-swscale',
             '--enable-filter=aformat,aresample,format,scale,overlay,yadif,bwdif,volume,pan,equalizer,loudnorm,bobtv_spectrum',
             '--target-os=mingw32', '--enable-cross-compile', '--arch=' + ('x86_64' if arch == 'x64' else 'aarch64'),
             '--cc=' + str(clang), '--cross-prefix=' + str(toolchain / 'bin' / (triple + '-')),
             '--ar=' + str(toolchain / 'bin/llvm-ar'), '--ranlib=' + str(toolchain / 'bin/llvm-ranlib'),
             '--nm=' + str(toolchain / 'bin/llvm-nm'), '--strip=' + str(toolchain / 'bin/llvm-strip'),
             '--prefix=' + str(install), '--extra-cflags=-D_WIN32_WINNT=0x0A00']
    fingerprint = hashlib.sha256(('\n'.join(flags) + digest(ROOT / 'tools/native/af_bobtv_spectrum.c')).encode()).hexdigest()
    stamp = binary_dir / 'fingerprint'
    if not stamp.exists() or stamp.read_text() != fingerprint:
        run(*flags, cwd=binary_dir)
        run('make', '-j8', cwd=binary_dir)
        stamp.write_text(fingerprint)
    produced = list((binary_dir / 'libavfilter').glob('avfilter-*.dll'))
    if len(produced) != 1: raise RuntimeError('Custom avfilter DLL was not produced')
    bundled = output / arch
    bundled.mkdir(parents=True, exist_ok=True)
    candidates = {file.name.lower(): file for file in (sysroot / 'bin').glob('*.dll')}
    candidates[produced[0].name.lower()] = produced[0]
    pending_dlls = ['libmpv-2.dll']; used = {}
    while pending_dlls:
        name = pending_dlls.pop().lower()
        if name in used or name not in candidates: continue  # OS system DLLs remain external
        path = candidates[name]
        used[name] = path
        pe = pefile.PE(str(path), fast_load=True)
        pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT']])
        for entry in getattr(pe, 'DIRECTORY_ENTRY_IMPORT', []):
            pending_dlls.append(entry.dll.decode().lower())
        expected = 0x8664 if arch == 'x64' else 0xaa64
        if pe.FILE_HEADER.Machine != expected: raise RuntimeError('Architecture mismatch: ' + name)
        pe.close()
        shutil.copy2(path, bundled / path.name)
    if produced[0].name.lower() not in used: raise RuntimeError('libmpv did not load the custom shared avfilter')
    notices = bundled / 'ThirdPartyNotices/NativeAudioSpectrum'
    notices.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_tar, notices)
    shutil.copy2(ROOT / 'tools/native/af_bobtv_spectrum.c', notices)
    shutil.copy2(Path(__file__), notices)
    shutil.copy2(source / 'COPYING.LGPLv2.1', notices)
    record = {'architecture': arch, 'repo': repo, 'ffmpegVersion': ffversion,
              'fftSourceSha256': digest(ROOT / 'tools/native/af_bobtv_spectrum.c'),
              'llvm': {'name': LLVM_NAME, 'sha256': LLVM_SHA256},
              'packages': {name: {'version': value['VERSION'][0], 'filename': value['FILENAME'][0], 'sha256': value['SHA256SUM'][0],
                          'source': 'https://github.com/msys2/MINGW-packages/tree/master/mingw-w64-' + name[len(prefix):]} for name,value in selected.items()},
              'files': {name: digest(bundled / path.name) for name,path in used.items()}}
    (notices / 'runtime-build.json').write_text(json.dumps(record, indent=2))
    print(json.dumps({'architecture':arch,'files':len(used),'ffmpegVersion':ffversion},indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['x64','arm64'], required=True)
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.arch, args.cache.resolve(), args.output.resolve())
