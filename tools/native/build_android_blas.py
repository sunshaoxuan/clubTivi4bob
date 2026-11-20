"""Pinned SSE-only BLAS for Android x64 devices without AVX2."""
import hashlib
import json
from pathlib import Path
import subprocess

TAG='v0.3.34'
TAG_SHA='e0166008be8e466242aa76b2ff75ce3f0fbf574a'
def run(*args,**kw):subprocess.run([str(a) for a in args],check=True,**kw)
def prepare(cache,cc,ar,ranlib):
    source=cache/'OpenBLAS-android-x64'
    if not source.exists():run('git','clone','--depth','1','--branch',TAG,'https://github.com/OpenMathLib/OpenBLAS.git',source)
    assert subprocess.check_output(['git','-C',str(source),'rev-parse',TAG],text=True).strip()==TAG_SHA
    run('git','-C',source,'diff','--exit-code','HEAD')
    prefix=cache/'openblas-android-x64-install'
    options=['TARGET=CORE2','BINARY=64','OSNAME=Android','CROSS=1','DYNAMIC_ARCH=0','NOFORTRAN=1',
             'NO_LAPACK=1','USE_THREAD=1','NUM_THREADS=2','NO_AFFINITY=1','NO_SHARED=1',
             'HOSTCC=clang',f'CC={cc}',f'AR={ar}',f'RANLIB={ranlib}','CFLAGS=-O2 -fPIC']
    signature=hashlib.sha256(('\n'.join(options)+TAG_SHA).encode()).hexdigest()
    marker=prefix/'receipt.json'
    if not marker.exists() or json.loads(marker.read_text()).get('configuration')!=signature:
        run('make','-j4',*options,cwd=source)
        run('make',*options,f'PREFIX={prefix}','install',cwd=source)
        marker.write_text(json.dumps(dict(tag=TAG,tagSha256=TAG_SHA,configuration=signature,options=options),indent=2))
    library=prefix/'lib/libopenblas.a';assert library.is_file()
    module=prefix/'cmake';module.mkdir(exist_ok=True)
    (module/'FindBLAS.cmake').write_text(f'set(BLAS_FOUND TRUE)\nset(BLAS_LIBRARIES "{library}")\nset(BLAS_INCLUDE_DIRS "{prefix}/include")\n')
    return library,prefix/'include',module,source/'LICENSE',marker
