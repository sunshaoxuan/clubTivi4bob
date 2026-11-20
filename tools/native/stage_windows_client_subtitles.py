#!/usr/bin/env python3
"""Package one verified Windows PCM runtime with matching offline workers."""
import argparse,hashlib,json,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def stage(runtime,workers,output,arch):
    record=json.loads((runtime/'ThirdPartyNotices/NativeAudioSpectrum/runtime-build.json').read_text())
    assert record['pcmSourceSha256']==digest(ROOT/'tools/native/af_bobtv_pcm.c')
    assert record['fftSourceSha256']==digest(ROOT/'tools/native/af_bobtv_spectrum.c')
    for name,sha in record['files'].items():assert digest(runtime/name)==sha
    receipt=json.loads((workers/'receipt.json').read_text());assert receipt['architecture']==arch
    for file in [workers/'receipt.json',workers/'receipt-avx2.json']:
        if not file.exists():continue
        r=json.loads(file.read_text())
        for name,sha in r['sourceSha256'].items():assert digest(ROOT/'tools/native'/name)==sha
        for name,sha in r['files'].items():assert digest(workers/name)==sha
        for name,sha in r.get('models',{ 'ggml-base.en-q5_1.bin':r['modelSha256'] }).items():assert digest(workers/name)==sha
    output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED) as z:
        for root,prefix in [(runtime,''),(workers,'data/ClientASR/')]:
            for path in sorted(root.rglob('*')):
                if path.is_file():z.write(path,prefix+path.relative_to(root).as_posix())
    print(json.dumps(dict(filename=output.name,sha256=digest(output),url=output.resolve().as_uri())))
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--runtime',type=Path,required=True);p.add_argument('--workers',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--arch',choices=['x64','arm64'],required=True);a=p.parse_args();stage(a.runtime.resolve(),a.workers.resolve(),a.output.resolve(),a.arch)
