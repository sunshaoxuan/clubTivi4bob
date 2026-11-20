"""Build a pinned, decoder-free local HLS timestamp-normalization helper."""
import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess
ROOT=Path(__file__).resolve().parents[2]
FLAGS=['--disable-everything','--disable-autodetect','--disable-programs','--disable-doc','--disable-avdevice','--disable-avfilter','--disable-swscale','--disable-swresample','--disable-postproc','--enable-static','--disable-shared','--enable-avformat','--enable-avcodec','--enable-avutil','--enable-protocol=file,http,https,tcp,tls,crypto,pipe','--enable-demuxer=hls,mpegts','--enable-muxer=mpegts','--enable-parser=aac,h264','--enable-bsf=h264_mp4toannexb,extract_extradata,aac_adtstoasc','--enable-network','--enable-securetransport','--disable-x86asm']
def run(*args,**kwargs):subprocess.run([str(a) for a in args],check=True,**kwargs)
def prepare(app):
 source=ROOT/'build/native-audio-spectrum/ffmpeg-6.0'
 assert (source/'VERSION').read_text().strip()=='6.0'
 architectures=subprocess.check_output(['lipo','-archs',str(app/'Contents/MacOS/BobTV')],text=True).split()
 assert architectures and set(architectures)<={'x86_64','arm64'}
 outputs=[]
 for architecture in architectures:
  build=ROOT/'build/client-remux'/architecture;build.mkdir(parents=True,exist_ok=True)
  deployment='11.0' if architecture=='arm64' else '10.15'
  compiler=f'-arch {architecture} -mmacosx-version-min={deployment}'
  flags=FLAGS+['--enable-cross-compile','--target-os=darwin',f'--arch={"aarch64" if architecture=="arm64" else "x86_64"}',f'--extra-cflags={compiler}',f'--extra-ldflags={compiler}']
  marker=build/'configuration.json';configuration=json.dumps(dict(flags=flags,cleanConfigurationRevision=1))
  if not marker.exists() or marker.read_text()!=configuration:
   if (build/'Makefile').exists():run('make','distclean',cwd=build)
   run(source/'configure',*flags,cwd=build);marker.write_text(configuration)
  run('make','-j4',cwd=build)
  components=(build/'config_components.h').read_text()
  assert not re.search(r'#define CONFIG_[A-Z0-9_]+_(?:DECODER|ENCODER) 1',components)
  binary=build/'bobtv-client-remux'
  run('clang++','-std=c++17','-O2','-arch',architecture,f'-mmacosx-version-min={deployment}',ROOT/'tools/native/client_remux.cpp','-idirafter',build,'-idirafter',source,
      build/'libavformat/libavformat.a',build/'libavcodec/libavcodec.a',build/'libavutil/libavutil.a',
      '-framework','Security','-framework','CoreFoundation','-framework','CoreVideo','-pthread','-o',binary)
  outputs.append(binary)
 target=app/'Contents/Resources/ClientASR';target.mkdir(parents=True,exist_ok=True)
 helper=target/'bobtv-client-remux'
 run('lipo','-create',*outputs,'-output',helper)
 for file in [ROOT/'tools/native/client_remux.cpp',source/'COPYING.LGPLv2.1']:
  shutil.copy2(file,target/file.name)
 (target/'remux-receipt.json').write_text(json.dumps(dict(ffmpegVersion='6.0',architectures=architectures,configureFlags=FLAGS,sourceSha256=hashlib.sha256((ROOT/'tools/native/client_remux.cpp').read_bytes()).hexdigest(),decodersEnabled=False,encodersEnabled=False),indent=2))
 run('codesign','--force','--sign','-',helper)
if __name__=='__main__':
 import sys
 prepare(Path(sys.argv[1]))
