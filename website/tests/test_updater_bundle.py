import io
import json
from pathlib import Path
import zipfile

import pytest
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import updater_bundle as bundle
from test_mirror import module, sign_test_archive, update_zip


def test_real_component_contains_both_installers_and_is_version_scoped(tmp_path):
    path = tmp_path/'component.zip'
    bundle.build(Path(__file__).resolve().parents[2]/'assets/updater', path, '1.4.5+7')
    bundle.inspect(path, '1.4.5+7')
    with pytest.raises(ValueError, match='compatibility'):
        bundle.inspect(path, '1.4.5+8')
    with zipfile.ZipFile(path, 'a') as archive:
        archive.writestr('../outside.ps1', b'exit')
    with pytest.raises(ValueError, match='contents'):
        bundle.inspect(path, '1.4.5+7')


def test_mirror_publishes_authenticated_updater_for_both_windows_formats(tmp_path, monkeypatch):
    path = tmp_path/'component.zip'
    bundle.build(Path(__file__).resolve().parents[2]/'assets/updater', path, '1.4.5+7')
    component = path.read_bytes()
    signature = sign_test_archive(tmp_path, monkeypatch, component)
    import hashlib
    app = update_zip('windows-x64')
    app_name = 'BobTV-1.4.5-windows-x64.zip'
    component_name = 'BobTV-1.4.5-windows-x64-Updater.zip'
    def asset(name, data):
        return {'name': name, 'size': len(data), 'browser_download_url': name,
                'digest': 'sha256:'+hashlib.sha256(data).hexdigest()}
    package = {'platform':'windows-x64','filename':app_name,
        'sha256':hashlib.sha256(app).hexdigest(),'bytes':len(app),
        'updater':{'filename':component_name,'sha256':hashlib.sha256(component).hexdigest(),
            'bytes':len(component),'signature':signature}}
    metadata = json.dumps({'schema':1,'version':'1.4.5+7','displayVersion':'1.4.5','packages':[package]}).encode()
    responses = {app_name:app,component_name:component,module.UPDATE_METADATA:metadata}
    release = {'tag_name':'v1.4.5','published_at':'2026-11-23T00:00:00Z',
        'assets':[asset(n,b) for n,b in responses.items()]}
    monkeypatch.setattr(module,'DATA',tmp_path/'site')
    monkeypatch.setattr(module,'request',lambda url:io.BytesIO(
        json.dumps([release]).encode() if url==module.API else responses[url]))
    module.mirror()
    target = tmp_path/'site/updates/windows-x64/latest.json'
    latest = json.loads(target.read_text())
    assert latest['updater']['archive'].endswith(component_name)
    assert json.loads((tmp_path/'site/updates/approved.json').read_text())[component_name] == package['updater']['sha256']
    (tmp_path/'site/updates/files'/component_name).unlink()
    responses[component_name] = component[:-1]+bytes([component[-1]^1])
    with pytest.raises(ValueError, match='checksum'):
        module.mirror()
