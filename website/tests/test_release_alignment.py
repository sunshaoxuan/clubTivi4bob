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
    with pytest.raises(ValueError,match='seven platforms'):module.validate_matrix(value,'1.1.11+106')


def test_old_android_cannot_be_substituted():
    value=metadata();value['packages'][-1]['filename']='BobTV-1.1.10+103-android-x64.apk'
    with pytest.raises(ValueError,match='version/build mismatch'):module.validate_matrix(value,'1.1.11+106')


def test_matching_seven_platform_release():
    assert len(module.validate_matrix(metadata(),'1.1.11+106'))==7


def test_finalizer_rejects_partial_official_release(tmp_path,monkeypatch):
    import finalize_desktop_update_metadata as finalizer
    monkeypatch.setattr(sys,'argv',['finalize',str(tmp_path),'1.1.11+106','--platforms','windows-x64'])
    with pytest.raises(ValueError,match='all seven platforms'):finalizer.main()
    assert not (tmp_path/'BobTV-update-metadata.json').exists()
