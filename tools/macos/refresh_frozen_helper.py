"""Recompile sender Python modules in a verified, architecture-specific runtime.

The platform bootloader and native dependencies are retained. Bytecode is rebuilt
from current source with exactly the runtime's Python magic, then the whole app
must be re-signed. This permits identical sender policy on Intel and Apple Silicon.
"""
import argparse
import importlib.util
import marshal
from pathlib import Path
import struct
import subprocess
import tempfile

from PyInstaller.archive.readers import CArchiveReader
from PyInstaller.archive.writers import CArchiveWriter, ZlibArchiveWriter
from PyInstaller.utils.osx import fix_exe_for_code_signing


def refresh(binary, sources):
    binary, sources = Path(binary), Path(sources)
    subprocess.run(['codesign', '--remove-signature', str(binary)], check=True)
    archive = CArchiveReader(str(binary))
    raw_pyz = archive.extract('PYZ.pyz')
    if raw_pyz[4:8] != importlib.util.MAGIC_NUMBER:
        raise ValueError('Frozen runtime Python bytecode version differs')
    embedded = archive.open_embedded_archive('PYZ.pyz')
    modules = {name: embedded.extract(name) for name in embedded.toc}
    replacements = ('mac_source', 'video_relay', 'egress_policy')
    for name in replacements:
        path = sources / (name + '.py')
        modules[name] = compile(path.read_bytes(), path.name, 'exec')
    with tempfile.TemporaryDirectory(prefix='bobtv-helper-build-') as temporary:
        temporary = Path(temporary)
        entries = []
        for name in modules:
            kind = embedded.toc.get(name, (0,))[0]
            path = None if kind == 3 else '__init__.py' if kind == 1 else name + '.py'
            entries.append((name, path, 'PYMODULE'))
        pyz = temporary / 'PYZ.pyz'
        ZlibArchiveWriter(str(pyz), entries, modules)
        raw = binary.read_bytes()
        cookie = raw[archive._end_offset - archive._COOKIE_LENGTH:archive._end_offset]
        _, _, _, _, pyvers, pylib = struct.unpack(archive._COOKIE_FORMAT, cookie)
        if pyvers != 312:
            raise ValueError('Expected pinned Python 3.12 sender runtime')

        class RawWriter(CArchiveWriter):
            def _write_entry(self, output, entry):
                name, data, compressed, kind = entry
                return self._write_blob(output, data, name, kind, compress=compressed)

        pkg_entries = [(option, b'', False, 'o') for option in archive.options]
        for name, (_, _, _, compressed, kind) in archive.toc.items():
            data = archive.extract(name)
            if name == 'PYZ.pyz':
                data = pyz.read_bytes()
            elif name == 'bobtv_airplay':
                data = marshal.dumps(compile((sources / 'bobtv_airplay.py').read_bytes(), 'bobtv_airplay.py', 'exec'))
            pkg_entries.append((name, data, bool(compressed), kind))
        pkg = temporary / 'sender.pkg'
        RawWriter(str(pkg), pkg_entries, pylib.rstrip(b'\0').decode('ascii'))
        binary.write_bytes(raw[:archive._start_offset] + pkg.read_bytes())
        binary.chmod(0o755)
    fix_exe_for_code_signing(str(binary))
    rebuilt = CArchiveReader(str(binary)).open_embedded_archive('PYZ.pyz')
    for name in replacements:
        if rebuilt.extract(name) != modules[name]:
            raise ValueError('Frozen sender module differs from source: ' + name)
    print('Rebuilt sender entrypoint and modules: ' + ', '.join(replacements))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('sources', type=Path)
    options = parser.parse_args()
    refresh(options.binary, options.sources)
