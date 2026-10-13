import importlib.util
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('package_signpath', ROOT / 'tools/package_signpath_candidate.py')
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


def test_only_manual_scoped_standard_runner_without_publish_permissions():
    # actionlint performs full YAML/expression validation separately. These
    # focused regressions need no new dependency in the production web service.
    workflow = (ROOT / '.github/workflows/windows-signpath.yml').read_text()
    events = workflow.split('\non:\n', 1)[1].split('\npermissions:', 1)[0]
    assert '  workflow_dispatch:' in events
    assert not re.search(r'^\s+(push|pull_request|schedule|release|workflow_run):', events, re.M)
    assert 'permissions:\n  contents: read\n  actions: read' in workflow
    assert not re.search(r'^\s+(contents|actions|packages|id-token): write', workflow, re.M)
    assert 'runs-on: windows-2022' in workflow
    assert "github.ref == 'refs/heads/main'" in workflow
    assert "github.repository == 'sunshaoxuan/clubTivi4bob'" in workflow
    for action in re.findall(r'uses: ([^\s#]+)', workflow):
        assert len(action.split('@')[-1]) == 40
    assert 'gh release' not in workflow
    uploads = [step for step in workflow.split('\n      - ') if 'uses: actions/upload-artifact@' in step]
    assert len(uploads) == 3
    assert all('if:' in step for step in uploads)
    assert all('retention-days: 7' in step for step in uploads)
    assert "if ($env:STORAGE_CONFIRMED -ne 'true')" in workflow
    assert 'BOBTV_UPDATE_SIGNING_KEY' not in workflow


def test_scope_is_main_app_and_setup_not_third_party_binaries():
    ns = {'s': 'http://signpath.io/artifact-configuration/v1'}
    for filename in ('bobtv-app.xml', 'bobtv-setup.xml'):
        tree = ET.parse(ROOT / 'tools/signpath' / filename)
        files = tree.findall('.//s:pe-file', ns)
        assert len(files) == 1
        file = files[0]
        assert file.attrib['product-name'] == 'BobTV'
        assert file.attrib['product-version'] == '${version}'
        assert file.attrib['file-version'] == '${version}'
        assert '.dll' not in file.attrib['path'] and 'AirPlay' not in file.attrib['path']
        assert file.find('s:authenticode-sign', ns) is not None


def test_candidate_packager_normalizes_names_and_does_not_publish(tmp_path):
    bundle = tmp_path / 'bundle'
    (bundle / 'data').mkdir(parents=True)
    (bundle / 'BobTV.exe').write_bytes(b'MZ-fixture')
    (bundle / 'data' / 'app.so').write_bytes(b'fixture')
    setup = tmp_path / 'BobTV-1.1.2+95-windows-x64-Setup.exe'
    setup.write_bytes(b'MZ-setup-fixture')
    output = tmp_path / 'candidate'
    packager.package(bundle, setup, output, '1.1.2+95', 'x64', 'unsigned')
    manifest = json.loads((output / 'candidate-manifest.json').read_text())
    assert manifest['publicRelease'] is False
    assert manifest['requiresFreshPublisherUpdateMetadata'] is True
    archive = next(output.glob('*.zip'))
    with zipfile.ZipFile(archive) as contents:
        assert contents.namelist() == ['BobTV/BobTV.exe', 'BobTV/data/app.so']
        assert all('\\' not in name for name in contents.namelist())


@pytest.mark.parametrize('filename,body', [('procdump64.exe', b'fixture'), ('private.p12', b'binary'), ('private.pfx', b'binary'), ('private.pem', b'-----BEGIN PRIVATE KEY-----')])
def test_candidate_rejects_non_oss_helper_and_private_keys(tmp_path, filename, body):
    bundle = tmp_path / 'bundle'
    bundle.mkdir()
    (bundle / 'BobTV.exe').write_bytes(b'MZ-fixture')
    (bundle / filename).write_bytes(body)
    setup = tmp_path / 'Setup.exe'
    setup.write_bytes(b'MZ-fixture')
    with pytest.raises(ValueError):
        packager.package(bundle, setup, tmp_path / 'out', '1.1.2+95', 'x64', 'unsigned')


def test_privacy_notice_and_default_choice_are_in_installer():
    setup = (ROOT / 'tools/windows/installer/BobTV.iss').read_text()
    assert 'InfoBeforeFile=PrivacyNotice.txt' in setup
    assert 'privatefavoritesbackup' in setup and '[BobTVPrivacy]' not in setup
    assert 'Section: "BobTVPrivacy"' in setup
    notice = (ROOT / 'tools/windows/installer/PrivacyNotice.txt').read_text(encoding='utf-8-sig')
    assert '/privacy' in notice and '默认关闭' in notice


def test_policy_routes_and_current_release_boundary():
    sys.path.insert(0, str(ROOT / 'website'))
    try:
        spec = importlib.util.spec_from_file_location('signpath_site', ROOT / 'website/app.py')
        app = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(app)
    finally:
        sys.path.remove(str(ROOT / 'website'))
    from fastapi.testclient import TestClient
    client = TestClient(app.app)
    for path in ('/privacy', '/code-signing'):
        assert client.get(path).status_code == 200
        assert client.head(path).status_code == 200
    policy = client.get('/code-signing').text
    assert '尚未批准' in policy and 'Code signing policy' in policy
    assert 'SignPath Foundation' in policy and 'sunshaoxuan' in policy
    privacy = client.get('/privacy').text
    assert '现有正式版 1.1.2' in privacy and '默认关闭' in privacy
    for path in ('/', '/downloads', '/diagnostics'):
        body = client.get(path).text
        assert 'href="/privacy"' in body and 'href="/code-signing"' in body
    for locale in ('zh-CN', 'zh-TW', 'en', 'ja'):
        body = client.get('/downloads', params={'lang': locale}).text
        assert 'SignPath Foundation' in body and 'SignPath.io' in body
