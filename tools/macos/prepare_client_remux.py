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
 architecture=subprocess.check_output(['uname','-m'],text=True).strip()
 build=ROOT/'build/client-remux'/architecture;build.mkdir(parents=True,exist_ok=True)
 marker=build/'configuration.json';configuration=json.dumps(FLAGS)
 if not marker.exists() or marker.read_text()!=configuration:
  run(source/'configure',*FLAGS,cwd=build);marker.write_text(configuration)
 run('make','-j4',cwd=build)
 components=(build/'config_components.h').read_text()
 assert not re.search(r'#define CONFIG_[A-Z0-9_]+_(?:DECODER|ENCODER) 1',components), 'stream-copy helper must not contain a decoder or encoder'
 target=app/'Contents/Resources/ClientASR';target.mkdir(parents=True,exist_ok=True)
 helper=target/'bobtv-client-remux'
 run('clang++','-std=c++17','-O2',ROOT/'tools/native/client_remux.cpp','-idirafter',build,'-idirafter',source,
     build/'libavformat/libavformat.a',build/'libavcodec/libavcodec.a',build/'libavutil/libavutil.a',
     '-framework','Security','-framework','CoreFoundation','-framework','CoreVideo','-pthread','-o',helper)
 for file in [ROOT/'tools/native/client_remux.cpp',source/'COPYING.LGPLv2.1']:
  shutil.copy2(file,target/file.name)
 (target/'remux-receipt.json').write_text(json.dumps(dict(ffmpegVersion='6.0',architecture=architecture,configureFlags=FLAGS,sourceSha256=hashlib.sha256((ROOT/'tools/native/client_remux.cpp').read_bytes()).hexdigest(),decodersEnabled=False,encodersEnabled=False),indent=2))
 run('codesign','--force','--sign','-',helper)
if __name__=='__main__':
 import sys
 prepare(Path(sys.argv[1]))
