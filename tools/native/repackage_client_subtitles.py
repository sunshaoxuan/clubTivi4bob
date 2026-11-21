"""Combine verified PCM runtimes with newly built, source-matched ASR workers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
MODELS = {
    'ggml-base-q5_1.bin': '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898',
    'ggml-tiny-q5_1.bin': '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_workers(folder, platform, arch):
    files = {}
    for name in ('receipt.json', 'receipt-avx2.json'):
        path = folder/name
        if not path.exists():
            if name == 'receipt.json' or arch == 'x64':
                raise ValueError('Missing worker receipt: '+str(path))
            continue
        receipt = json.loads(path.read_text())
        assert receipt['platform'] == platform and receipt['architecture'] == arch
        assert not receipt['decodersEnabled'] and not receipt['encodersEnabled']
        for source, expected in receipt['sourceSha256'].items():
            assert digest(ROOT/'tools/native'/source) == expected, source
        for model, expected in receipt['models'].items():
            assert MODELS[model] == expected and digest(folder/model) == expected
        for file, expected in receipt['files'].items():
            assert digest(folder/file) == expected, file
            files[file] = folder/file
        files[name] = path
    assert MODELS.keys() >= json.loads((folder/'receipt.json').read_text())['models'].keys()
    return files


def package(previous, workers, output, tag):
    lock = json.loads((ROOT/'tools/native/runtime-lock.json').read_text())
    for field, source in [('fftSourceSha256','af_bobtv_spectrum.c'),
                          ('pcmSourceSha256','af_bobtv_pcm.c')]:
        assert lock[field] == digest(ROOT/'tools/native'/source)
    output.mkdir(parents=True, exist_ok=True)
    provenance = []
    for platform, arch, key in [('windows','x64','x64'),('windows','arm64','arm64'),
            ('android','arm','armeabi-v7a'),('android','arm64','arm64-v8a'),('android','x64','x86_64')]:
        item = lock[platform][key]
        original = previous/item['filename']
        assert digest(original) == item['sha256']
        folder = workers/f'multilingual-workers-{platform}-{arch}'
        verified = checked_workers(folder, platform, arch)
        target = output/item['filename']
        with zipfile.ZipFile(original) as old, zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as new:
            names = old.namelist()
            assert len(names) == len(set(names))
            for member in names:
                if '\\' in member or member.startswith('/') or '..' in Path(member).parts:
                    raise ValueError('Unsafe runtime archive member')
                if platform == 'windows' and member.startswith('data/ClientASR/'):
                    continue
                if platform == 'android' and member.startswith(f'lib/{key}/libbobtv_client_'):
                    continue
                new.writestr(member, old.read(member))
            prefix = 'data/ClientASR/' if platform == 'windows' else f'lib/{key}/'
            notices = prefix if platform == 'windows' else f'META-INF/client-subtitles/{key}/'
            for name, path in verified.items():
                new.write(path, (notices if name.endswith('.json') else prefix)+name)
            for path in sorted((folder/'sources-and-licenses').rglob('*')):
                if path.is_file():
                    new.write(path, notices+'sources-and-licenses/'+path.relative_to(folder/'sources-and-licenses').as_posix())
            if platform == 'windows':
                for name in json.loads((folder/'receipt.json').read_text())['models']:
                    new.write(folder/name, prefix+name)
        lock[platform][key] = dict(filename=target.name, sha256=digest(target),
            url=f'https://github.com/sunshaoxuan/clubTivi4bob/releases/download/{tag}/{target.name}')
        provenance.append(dict(platform=platform, architecture=arch, baseArchiveSha256=item['sha256'],
            outputSha256=digest(target), workerReceipts={name:digest(folder/name)
                for name in verified if name.endswith('.json')}))
    target = output/'bobtv-client-subtitle-models.jar'
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED) as archive:
        for name, expected in MODELS.items():
            path = workers/'multilingual-workers-android-arm'/name
            assert digest(path) == expected
            archive.write(path, 'bobtv-client-subtitles/'+name)
    lock['clientSubtitleModels'] = dict(filename=target.name,sha256=digest(target),
        url=f'https://github.com/sunshaoxuan/clubTivi4bob/releases/download/{tag}/{target.name}')
    lock['version'] = tag.removeprefix('bobtv-')
    lock['clientWorkerSourceCommit'] = subprocess.check_output(
        ['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    (output/'runtime-lock.json').write_text(json.dumps(lock,indent=2)+'\n')
    (output/'provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print(json.dumps(dict(archives=6, models=list(MODELS), output=str(output))))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previous',type=Path,required=True)
    parser.add_argument('--workers',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--tag',required=True)
    args=parser.parse_args()
    package(args.previous,args.workers,args.output,args.tag)
