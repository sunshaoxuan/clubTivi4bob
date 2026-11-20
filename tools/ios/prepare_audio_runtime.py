#!/usr/bin/env python3
"""Build the pinned LGPL PCM filter for the selected iOS SDK. Never modify Pods."""
import argparse, hashlib, os, re, shutil, subprocess, tarfile, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SHA = '57be87c22d9b49c112b6d24bc67d42508660e6b718b3db89c44e47e289137082'
def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.STDOUT, text=True)
def prepare(platform, arch, app=None):
    cache = ROOT/'build/native-ios-audio'; cache.mkdir(parents=True, exist_ok=True)
    archive = cache/'ffmpeg-6.0.tar.xz'
    if not archive.exists():
        temp=archive.with_suffix('.download');urllib.request.urlretrieve('https://ffmpeg.org/releases/ffmpeg-6.0.tar.xz',temp);temp.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=SHA: raise RuntimeError('FFmpeg checksum mismatch')
    source=cache/'ffmpeg-6.0'
    if not source.exists():
        with tarfile.open(archive) as tar: tar.extractall(cache)
    patch=ROOT/'tools/native/af_bobtv_pcm.c';shutil.copy2(patch,source/'libavfilter/af_bobtv_pcm.c')
    registry=source/'libavfilter/allfilters.c';text=registry.read_text()
    if 'extern const AVFilter ff_af_bobtv_pcm;' not in text: registry.write_text(text.replace('extern const AVFilter ff_af_astats;', 'extern const AVFilter ff_af_astats;\nextern const AVFilter ff_af_bobtv_pcm;'))
    makefile=source/'libavfilter/Makefile';text=makefile.read_text()
    if 'CONFIG_BOBTV_PCM_FILTER' not in text:makefile.write_text(text+'\nOBJS-$(CONFIG_BOBTV_PCM_FILTER) += af_bobtv_pcm.o\n')
    # Bind avutil APIs directly. FFmpeg's wildcard Darwin export lists also
    # re-export dependency symbols; the shipped codec re-exports only a subset.
    sdk=run('xcrun' ,'--sdk',platform,'--show-sdk-path').strip()
    target=f'{arch}-apple-ios13.0'+('-simulator' if platform=='iphonesimulator' else '')
    directory=cache/f'{platform}-{arch}';directory.mkdir(exist_ok=True);prefix=directory/'install'
    filters='aformat,asplit,pan,bandpass,amerge,astats,aresample,equalizer,volume,loudnorm,bobtv_pcm'
    fingerprint=hashlib.sha256((SHA+target+filters+'avformat-mpegts-v1'+patch.read_text()).encode()).hexdigest()
    binary=directory/'Avfilter';stamp=directory/'fingerprint'
    if not binary.exists() or not stamp.exists() or stamp.read_text()!=fingerprint:
        flags=f'-target {target} -isysroot {sdk}'
        configure=[str(source/'configure'),'--disable-decoders','--disable-encoders','--disable-muxers','--enable-muxer=mpegts,mov,matroska','--disable-demuxer=fits','--disable-filters','--enable-securetransport','--enable-zlib','--disable-autodetect','--disable-programs','--disable-doc','--disable-avdevice','--enable-avformat','--enable-avcodec','--disable-postproc','--disable-swscale','--disable-x86asm','--enable-shared','--disable-static','--enable-avfilter','--enable-swresample',f'--enable-filter={filters}',f'--prefix={prefix}','--cc=clang','--target-os=darwin','--enable-cross-compile',f'--arch={"aarch64" if arch=="arm64" else "x86_64"}',f'--extra-cflags={flags}',f'--extra-ldflags={flags}']
        for name,args in [('configure',configure),('build',['make','-j4']),('headers',['make','install-headers'])]:
            print(f'iOS audio {name}: {platform} {arch}',flush=True)
            try:(directory/(name+'.log')).write_text(run(*args,cwd=directory))
            except subprocess.CalledProcessError as error:
                (directory/(name+'.log')).write_text(error.output);raise
        shutil.copy2(directory/'libavfilter/libavfilter.9.dylib',binary)
        run('install_name_tool','-id','@rpath/Avfilter.framework/Avfilter','-change',str(prefix/'lib/libavutil.58.dylib'),'@rpath/Avutil.framework/Avutil','-change',str(prefix/'lib/libswresample.4.dylib'),'@rpath/Swresample.framework/Swresample',str(binary))
        stamp.write_text(fingerprint)
    format_binary=directory/'Avformat'
    link_stamp=directory/'format-link-order'
    if not format_binary.exists() or not link_stamp.exists() or link_stamp.read_text()!=fingerprint+'-avutil-first-v2':
        (directory/'libavformat/libavformat.60.dylib').unlink(missing_ok=True)
        (directory/'format-link.log').write_text(run('make','-j4','avformat_FFLIBS=avutil avcodec','libavformat/libavformat.60.dylib',cwd=directory))
        shutil.copy2(directory/'libavformat/libavformat.60.dylib',format_binary)
        run('install_name_tool','-id','@rpath/Avformat.framework/Avformat',
            '-change',str(prefix/'lib/libavutil.58.dylib'),'@rpath/Avutil.framework/Avutil',
            '-change',str(prefix/'lib/libavcodec.60.dylib'),'@rpath/Avcodec.framework/Avcodec',str(format_binary))
        link_stamp.write_text(fingerprint+'-avutil-first-v2')
    headers=cache/'headers/include';headers.mkdir(parents=True,exist_ok=True)
    # Remux code consumes the public FFmpeg headers, not private build config.
    for library in ['libavutil','libavformat','libavcodec','libavfilter','libswresample']:
        destination=headers/library;destination.mkdir(exist_ok=True)
        for header in (source/library).glob('*.h'):shutil.copy2(header,destination/header.name)
    shutil.copy2(directory/'libavutil/avconfig.h',headers/'libavutil/avconfig.h')
    shutil.copy2(directory/'libavutil/ffversion.h',headers/'libavutil/ffversion.h')
    print(str(binary),flush=True)
    return binary

def verify_abi(binaries, app):
    frameworks=app/'Frameworks'
    for name,version in [('Avcodec','60.3.100'),('Avutil','58.2.100'),('Avfilter','9.3.100'),('Avformat','60.3.100')]:
        if f'current version {version}' not in run('otool','-L',str(frameworks/f'{name}.framework/{name}')):
            raise RuntimeError(f'Review pinned FFmpeg ABI before replacing {name}')
    for binary in binaries:
        for arch in run('lipo','-archs',str(binary)).split():
            provided=set()
            for name in ['Avcodec','Avutil','Swresample']:
                provided.update(re.findall(r'(_av\w+)',run('nm','-arch',arch,'-gU',str(frameworks/f'{name}.framework/{name}'))))
            exports={name:set(re.findall(r'(_av\w+)',run('xcrun','dyld_info','-arch',arch,'-exports',str(frameworks/f'{name}.framework/{name}')))) for name in ['Avcodec','Avutil','Swresample']}
            for name in ['Avfilter','Avformat']:
                imports=run('xcrun','dyld_info','-arch',arch,'-imports',str(binary.parent/name))
                for symbol,owner in re.findall(r'(_av\w+)\s+\(from (Avcodec|Avutil|Swresample)\)',imports):
                    if symbol not in exports[owner]: raise RuntimeError(f'{name} imports {symbol} from incompatible {owner}')
                needed=set(re.findall(r'(_av\w+)',run('nm','-arch',arch,'-u',str(binary.parent/name))))
                if needed-provided: raise RuntimeError(f'{name} has unavailable FFmpeg symbols: {sorted(needed-provided)}')

def embed(binaries, app):
    verify_abi(binaries,app)
    identity=os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
    for library in ['Avfilter','Avformat']:
        framework=app/f'Frameworks/{library}.framework'
        libraries=[binary.parent/library for binary in binaries]
        if len(libraries)==1: shutil.copy2(libraries[0],framework/library)
        else: run('lipo','-create',*[str(binary) for binary in libraries],'-output',str(framework/library))
        run('codesign','--force','--sign',identity,str(framework))
    notices=app/'NativeAudioSpectrum';notices.mkdir(exist_ok=True)
    cache=ROOT/'build/native-ios-audio'
    for file in [cache/'ffmpeg-6.0.tar.xz',cache/'ffmpeg-6.0/COPYING.LGPLv2.1',ROOT/'tools/native/af_bobtv_pcm.c',Path(__file__)]: shutil.copy2(file,notices/file.name)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--platform',default=os.environ.get('PLATFORM_NAME','iphonesimulator'));p.add_argument('--arch',default=os.environ.get('ARCHS','x86_64'));p.add_argument('--app',type=Path)
    a=p.parse_args();architectures=a.arch.split()
    if not architectures or any(arch not in ['arm64','x86_64'] for arch in architectures): raise RuntimeError('Unsupported iOS architecture')
    binaries=[prepare(a.platform,arch) for arch in architectures]
    if a.app:embed(binaries,a.app)
