#!/usr/bin/env python3
"""Embed the PCM analysis filters missing from media-kit's minimal FFmpeg 6.0.

Called after CocoaPods embeds frameworks and before Xcode signs the app. Only
Avfilter is rebuilt, retaining the shipped libavutil/libswresample ABI. No
installed application or dependency-cache framework is modified.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

VERSION = '6.0'
SHA256 = '57be87c22d9b49c112b6d24bc67d42508660e6b718b3db89c44e47e289137082'
FILTERS = 'aformat,asplit,pan,bandpass,amerge,astats,aresample,equalizer,overlay,bobtv_spectrum'
ROOT = Path(__file__).resolve().parents[2]


def run(*args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env, stderr=subprocess.STDOUT, text=True)


def prepare(app, cache):
    frameworks = app / 'Contents/Frameworks'
    binary = frameworks / 'Avfilter.framework/Versions/A/Avfilter'
    links = run('otool', '-L', str(binary))
    if 'current version 9.3.100' not in links:
        raise RuntimeError('Review the FFmpeg ABI before updating the pinned spectrum build')
    architectures = run('lipo', '-archs', str(binary)).split()
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'ffmpeg-{VERSION}.tar.xz'
    if not archive.exists():
        temporary = archive.with_suffix('.download')
        urllib.request.urlretrieve(f'https://ffmpeg.org/releases/{archive.name}', temporary)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError('FFmpeg source checksum mismatch')
    source = cache / f'ffmpeg-{VERSION}'
    if not source.is_dir():
        with tarfile.open(archive) as tar:
            # The exact archive hash is checked before extraction.
            tar.extractall(cache)
    patch = ROOT / 'tools/native/af_bobtv_spectrum.c'
    if not patch.exists():
        patch = Path(__file__).with_name('af_bobtv_spectrum.c')
    shutil.copy2(patch, source / 'libavfilter/af_bobtv_spectrum.c')
    registry = source / 'libavfilter/allfilters.c'
    text = registry.read_text()
    if 'extern const AVFilter ff_af_bobtv_spectrum;' not in text:
        registry.write_text(text.replace('extern const AVFilter ff_af_astats;',
            'extern const AVFilter ff_af_astats;\nextern const AVFilter ff_af_bobtv_spectrum;'))
    makefile = source / 'libavfilter/Makefile'
    text = makefile.read_text()
    if 'CONFIG_BOBTV_SPECTRUM_FILTER' not in text:
        makefile.write_text(text + '\nOBJS-$(CONFIG_BOBTV_SPECTRUM_FILTER) += af_bobtv_spectrum.o\n')
    outputs = []
    for arch in architectures:
        directory = cache / ('fft-v1-' + arch)
        directory.mkdir(exist_ok=True)
        output = directory / 'Avfilter'
        fingerprint = hashlib.sha256((SHA256 + FILTERS + arch + 'macos12-v2' + hashlib.sha256(patch.read_bytes()).hexdigest()).encode()).hexdigest()
        stamp = directory / 'fingerprint'
        if not output.exists() or not stamp.exists() or stamp.read_text() != fingerprint:
            # Copied build caches may contain a source snapshot or an absolute
            # Makefile from another checkout. Point every rebuild at this source.
            link = directory / 'src'
            if link.exists() and not link.is_symlink():
                retired = directory / 'source-before-relocation'
                if retired.exists():
                    raise RuntimeError(f'Review relocated source cache: {retired}')
                link.rename(retired)
            if link.is_symlink() and link.resolve() != source.resolve():
                link.unlink()
            if not link.exists():
                link.symlink_to(source, target_is_directory=True)
            (directory / 'Makefile').write_text(f'include {source}/Makefile\n')
            flags = [f'-arch {arch}', '-mmacosx-version-min=12.0']
            prefix = directory / 'install'
            env = {**os.environ, 'MACOSX_DEPLOYMENT_TARGET': '12.0'}
            print(f'Building real audio analysis filters for macOS {arch}', flush=True)
            configure = [str(source / 'configure'), '--disable-everything', '--disable-autodetect',
                         '--disable-programs', '--disable-doc', '--disable-avdevice',
                         '--disable-avformat', '--disable-avcodec', '--disable-postproc',
                         '--disable-swscale', '--disable-x86asm', '--enable-shared',
                         '--disable-static', '--enable-avfilter', '--enable-swresample',
                         f'--enable-filter={FILTERS}', f'--prefix={prefix}',
                         '--cc=clang', '--target-os=darwin', '--enable-cross-compile',
                         f'--arch={"aarch64" if arch == "arm64" else "x86_64"}',
                         f'--extra-cflags={" ".join(flags)}', f'--extra-ldflags={" ".join(flags)}']
            try:
                (directory / 'configure.log').write_text(run(*configure, cwd=directory, env=env))
                (directory / 'build.log').write_text(run('make', '-j8', cwd=directory, env=env))
            except subprocess.CalledProcessError as error:
                (directory / 'failure.log').write_text(error.output)
                raise RuntimeError(f'Native spectrum build failed: {directory / "failure.log"}') from error
            shutil.copy2(directory / 'libavfilter/libavfilter.9.dylib', output)
            run('install_name_tool', '-id', '@rpath/Avfilter.framework/Versions/A/Avfilter',
                '-change', str(prefix / 'lib/libavutil.58.dylib'), '@rpath/Avutil.framework/Versions/A/Avutil',
                '-change', str(prefix / 'lib/libswresample.4.dylib'), '@rpath/Swresample.framework/Versions/A/Swresample',
                str(output))
            stamp.write_text(fingerprint)
        outputs.append(str(output))
    combined = cache / 'Avfilter-universal'
    run('lipo', '-create', *outputs, '-output', str(combined))
    shutil.copy2(combined, binary)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    run('codesign', '--force', '--sign', identity, str(frameworks / 'Avfilter.framework'))
    sources = app / 'Contents/Resources/NativeAudioSpectrum'
    sources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(archive, sources / archive.name)
    shutil.copy2(source / 'COPYING.LGPLv2.1', sources)
    shutil.copy2(Path(__file__), sources)
    shutil.copy2(patch, sources)
    print(f'Embedded real audio spectrum filters: {", ".join(architectures)}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--cache', type=Path, default=ROOT / 'build/native-audio-spectrum')
    args = parser.parse_args()
    prepare(args.app.resolve(), args.cache.resolve())
