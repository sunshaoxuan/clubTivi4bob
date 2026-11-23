"""Signed, bounded Windows updater component shared by Setup and portable apps."""
import json
from pathlib import Path
import re
import zipfile

FILES = ('worker.ps1', 'installer_worker.ps1', 'publisher_signature.ps1',
         'progress_ui.ps1', 'update-signing-public.pem')
MAX_BYTES = 2 * 1024 * 1024


def inspect(path, version):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(n.lower() for n in names)) or set(names) != {*FILES, 'updater.json'}:
            raise ValueError('Unexpected updater bundle contents')
        if sum(e.file_size for e in archive.infolist()) > MAX_BYTES:
            raise ValueError('Updater bundle expanded limit')
        for entry in archive.infolist():
            if entry.is_dir() or ((entry.external_attr >> 16) & 0o170000) == 0o120000:
                raise ValueError('Updater bundle links are forbidden')
        metadata = json.loads(archive.read('updater.json'))
        if metadata != {'protocol': 1, 'version': version,
                        'modes': ['windows-managed', 'windows-portable']}:
            raise ValueError('Updater component compatibility mismatch')
        for name in FILES:
            if not archive.read(name):
                raise ValueError('Empty updater component')
    if not 1024 <= Path(path).stat().st_size <= MAX_BYTES:
        raise ValueError('Updater bundle size limit')


def build(source, output, version):
    if not re.fullmatch(r'\d+\.\d+\.\d+\+\d+', version):
        raise ValueError('Invalid native updater version')
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in FILES:
            text = (Path(source)/name).read_text(encoding='utf-8-sig')
            archive.writestr(name, text.encode('utf-8-sig' if name.endswith('.ps1') else 'utf-8'))
        archive.writestr('updater.json', json.dumps({'protocol': 1, 'version': version,
            'modes': ['windows-managed', 'windows-portable']}, separators=(',', ':')))
    inspect(output, version)
