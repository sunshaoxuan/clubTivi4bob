"""Build the self-contained LGPL AirPlay relay dependency from pinned source."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
SHA256 = '57be87c22d9b49c112b6d24bc67d42508660e6b718b3db89c44e47e289137082'
FLAGS = [
    '--disable-everything', '--disable-autodetect', '--disable-doc',
    '--disable-debug', '--disable-shared', '--enable-static',
    '--enable-ffmpeg', '--disable-ffplay', '--disable-ffprobe',
    '--disable-x86asm', '--enable-securetransport', '--enable-network',
    '--enable-protocol=file,http,https,tcp,tls,crypto,pipe',
    '--enable-demuxer=hls,mpegts,mov,aac,mp3',
    '--enable-muxer=hls,mpegts,adts',
    '--enable-parser=aac,h264,hevc,ac3,mpegaudio',
    '--enable-decoder=aac,ac3,eac3,mp3,mp3float', '--enable-encoder=aac',
    '--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc',
    '--enable-filter=aresample,anull,aformat',
]


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def prepare(app):
    archive = ROOT / 'build/native-audio-spectrum/ffmpeg-6.0.tar.xz'
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError('Pinned FFmpeg source checksum mismatch')
    cache = ROOT / 'build/cast-ffmpeg'
    cache.mkdir(parents=True, exist_ok=True)
    source = cache / 'ffmpeg-6.0'
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(cache)
    architectures = subprocess.check_output(
        ['lipo', '-archs', str(app / 'Contents/MacOS/BobTV')], text=True).split()
    if not architectures or set(architectures) - {'x86_64', 'arm64'}:
        raise ValueError('Unsupported Mac architecture')
    binaries = []
    for architecture in architectures:
        build = cache / architecture
        build.mkdir(exist_ok=True)
        deployment = '11.0' if architecture == 'arm64' else '10.15'
        compiler = f'-arch {architecture} -mmacosx-version-min={deployment}'
        flags = FLAGS + ['--enable-cross-compile', '--target-os=darwin',
                         '--arch=' + ('aarch64' if architecture == 'arm64' else 'x86_64'),
                         '--extra-cflags=' + compiler, '--extra-ldflags=' + compiler]
        marker = build / 'configuration.json'
        configuration = json.dumps(flags)
        if not marker.exists() or marker.read_text() != configuration:
            if (build / 'Makefile').exists():
                run('make', 'distclean', cwd=build)
            run(source / 'configure', *flags, cwd=build)
            marker.write_text(configuration)
        run('make', '-j4', 'ffmpeg', cwd=build)
        binaries.append(build / 'ffmpeg')
    target = app / 'Contents/Resources/Tools'
    target.mkdir(parents=True, exist_ok=True)
    output = target / 'ffmpeg'
    run('lipo', '-create', *binaries, '-output', output)
    output.chmod(0o755)
    links = subprocess.check_output(['otool', '-L', str(output)], text=True)
    if '/opt/homebrew/' in links or '/usr/local/' in links:
        raise ValueError('AirPlay FFmpeg must not depend on package-manager libraries')
    shutil.copy2(source / 'COPYING.LGPLv2.1', target / 'FFMPEG-LICENSE.txt')
    shutil.copy2(archive, target / 'FFMPEG-SOURCE.tar.xz')
    shutil.copy2(Path(__file__), target / 'prepare_cast_ffmpeg.py')
    (target / 'FFMPEG-BUILD.json').write_text(json.dumps({
        'sourceSha256': SHA256, 'version': '6.0',
        'architectures': architectures, 'configureFlags': FLAGS,
    }, indent=2) + '\n')
    run('codesign', '--force', '--sign', '-', output)
    run(output, '-version')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    prepare(parser.parse_args().app)
