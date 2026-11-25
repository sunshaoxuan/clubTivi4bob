import importlib.util
from pathlib import Path
import pytest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('release_alignment',ROOT/'tools/verify_release_alignment.py')
module=importlib.util.module_from_spec(spec)
import sys
sys.path.insert(0,str(ROOT/'tools'))
spec.loader.exec_module(module)


def metadata():
    return {'schema':1,'version':'1.1.11+106','packages':[
        {'platform':p,'filename':f"BobTV-1.1.11+106-{p}.{'apk' if p.startswith('android-') else 'zip'}"}
        for p in module.PLATFORMS]}


def test_all_platforms_are_required():
    value=metadata();value['packages']=[p for p in value['packages'] if not p['platform'].startswith('android-')]
    with pytest.raises(ValueError,match='platform matrix'):module.validate_matrix(value,'1.1.11+106')


def test_old_android_cannot_be_substituted():
    value=metadata();value['packages'][-1]['filename']='BobTV-1.1.10+103-android-x64.apk'
    with pytest.raises(ValueError,match='version/build mismatch'):module.validate_matrix(value,'1.1.11+106')


def test_matching_seven_platform_release():
    assert len(module.validate_matrix(metadata(),'1.1.11+106'))==7


def test_visible_counter_reset_keeps_android_installations_upgradeable():
    from android.version_code import split_install_code
    platforms = ['android-arm', 'android-arm64', 'android-x64']
    previous = [split_install_code('1.1.25+120', p) for p in platforms]
    current = [split_install_code('1.3.0+0', p) for p in platforms]
    assert current == [103001000, 103002000, 103004000]
    assert min(current) > max(previous)
    assert min(split_install_code('1.3.1+0', p) for p in platforms) > max(
        split_install_code('1.3.0+999', p) for p in platforms)
    with pytest.raises(ValueError):
        split_install_code('1.3.0+1000', 'android-arm64')


def test_finalizer_rejects_partial_official_release(tmp_path,monkeypatch):
    import finalize_desktop_update_metadata as finalizer
    monkeypatch.setattr(sys,'argv',['finalize',str(tmp_path),'1.1.11+106','--platforms','windows-x64'])
    with pytest.raises(ValueError,match='all seven platforms'):finalizer.main()
    assert not (tmp_path/'BobTV-update-metadata.json').exists()


def test_explicit_desktop_release_accepts_exactly_four_desktop_platforms():
    value=metadata()
    value['packages']=[p for p in value['packages'] if p['platform'] in module.DESKTOP_PLATFORMS]
    assert len(module.validate_matrix(value,'1.1.11+106',desktop_only=True)) == 4


def test_explicit_desktop_release_rejects_incomplete_matrix():
    value=metadata()
    value['packages']=[p for p in value['packages'] if p['platform'] in module.DESKTOP_PLATFORMS][:-1]
    with pytest.raises(ValueError,match='platform matrix'):
        module.validate_matrix(value,'1.1.11+106',desktop_only=True)


def test_public_semantic_names_preserve_native_build_identity():
    value=metadata()
    value['displayVersion']='1.1.11'
    for item in value['packages']:
        item['filename']=item['filename'].replace('1.1.11+106','1.1.11')
    assert len(module.validate_matrix(value,'1.1.11+106')) == 7
    value['displayVersion']='1.1.12'
    with pytest.raises(ValueError, match='Public version mismatch'):
        module.validate_matrix(value,'1.1.11+106')


@pytest.mark.parametrize('observer_version', ['1.0+1', '1.4.7+9', '1.4.7+10'])
def test_mac_observer_must_match_native_application_version(tmp_path, observer_version):
    import plistlib
    import zipfile
    archive_path = tmp_path / 'mac.zip'
    with zipfile.ZipFile(archive_path, 'w') as archive:
        for path, identifier, version in [
            ('BobTV.app/Contents/Info.plist', 'com.briconbric.bobtv', '1.4.7+10'),
            ('BobTV.app/Contents/Resources/Updater/BobTVUpdateProgress.app/Contents/Info.plist',
             'com.briconbric.bobtv.updater', observer_version),
        ]:
            base, build = version.split('+')
            archive.writestr(path, plistlib.dumps({'CFBundleIdentifier': identifier,
                'CFBundleShortVersionString': base, 'CFBundleVersion': build}))
    with zipfile.ZipFile(archive_path) as archive:
        if observer_version == '1.4.7+10':
            module.validate_mac_bundle_versions(archive, '1.4.7+10')
        else:
            with pytest.raises(ValueError, match='identity/version differs'):
                module.validate_mac_bundle_versions(archive, '1.4.7+10')
