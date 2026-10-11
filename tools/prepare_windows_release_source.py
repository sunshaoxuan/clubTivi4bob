"""Create a source-only, secret-free Windows build input from the current tree."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = ('lib/', 'assets/', 'windows/', 'third_party/', 'tools/', 'test/')
TOP = {'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'LICENSE', 'README.md'}

def prepare(output):
    output = Path(output)
    if output.exists():
        raise ValueError('Preserve existing build input')
    names = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    selected = sorted({name for name in names if name and (name in TOP or name.startswith(ALLOWED))})
    selected = [name for name in selected if not any(part in ('build', '.dart_tool', 'ephemeral', '__pycache__') for part in Path(name).parts)]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, 'w:gz') as archive:
        for name in selected:
            path = ROOT / name
            if path.is_file() and not path.is_symlink():
                archive.add(path, arcname=name, recursive=False)
    print({'files':len(selected), 'sha256':hashlib.sha256(output.read_bytes()).hexdigest(), 'bytes':output.stat().st_size})

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    prepare(parser.parse_args().output)
