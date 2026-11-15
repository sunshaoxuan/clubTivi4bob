"""Build a disposable production-code overlay for the existing EPG test suite."""
from pathlib import Path
import shutil
import tempfile
ROOT = Path(__file__).resolve().parents[2]
folder = Path(tempfile.mkdtemp(prefix='bobtv-epg-validation-'))/'website'
folder.mkdir()
for source in (ROOT/'website').glob('*.py'):
    shutil.copy2(source, folder/source.name)
for source in (ROOT/'website').glob('*.json'):
    shutil.copy2(source, folder/source.name)
shutil.copytree(ROOT/'website/deploy', folder/'deploy')
shutil.copytree(ROOT/'website/tests', folder/'tests', ignore=shutil.ignore_patterns('__pycache__'))
(folder/'assets').mkdir(exist_ok=True)
(folder/'templates').mkdir(exist_ok=True)
shutil.copytree(ROOT/'test/fixtures', folder.parent/'test/fixtures', dirs_exist_ok=True)
print(folder)
