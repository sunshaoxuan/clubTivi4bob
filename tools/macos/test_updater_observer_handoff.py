"""Test actual observer replacement with live player PID and no visible windows."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


def wait_for(predicate, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.1)
    raise AssertionError(label)


def main():
    binary = Path(sys.argv[1]).resolve()
    repository = Path(__file__).resolve().parents[2]
    processes = []
    with tempfile.TemporaryDirectory(prefix='bobtv-observer-handoff-') as temporary:
        root = Path(temporary)
        def start(name, run, *, replace=False, claim=True):
            app = root/(name+'.app')
            (app/'Contents/MacOS').mkdir(parents=True)
            shutil.copy2(binary, app/'Contents/MacOS/BobTVUpdateProgress')
            info = plistlib.loads((repository/'tools/macos/update_progress_info.plist').read_bytes())
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            if replace:
                (root/('progress-next-'+run+'.txt')).write_text(str(app))
            process = subprocess.Popen([str(app/'Contents/MacOS/BobTVUpdateProgress'),
                str(root), str(root/'Player.app'), str(os.getpid()), str(os.getpid()),
                '1.4.4+6', run], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process)
            owner = root/('progress-owner-'+run+'.txt')
            if claim:
                wait_for(lambda: owner.exists() and owner.read_text() == str(app), 'observer did not claim run')
            return process
        try:
            previous = start('previous', 'upgrade')
            unrelated = start('unrelated', 'other-upgrade')
            replacement = start('replacement', 'upgrade', replace=True)
            wait_for(lambda: previous.poll() is not None, 'previous observer did not retire')
            assert previous.returncode == 0
            assert replacement.poll() is None and unrelated.poll() is None
            late_previous = start('late-previous', 'upgrade', claim=False)
            wait_for(lambda: late_previous.poll() is not None, 'late old observer reclaimed run')
            assert late_previous.returncode == 0 and replacement.poll() is None
            os.kill(os.getpid(), 0)
            log = (root/'progress-ui.log').read_text()
            assert 'observer_replaced run=upgrade' in log
            assert 'window_shown' not in log
            print(json.dumps({'previousRetired': True, 'replacementRunning': True,
                'otherRunUnaffected': True, 'playerRunning': True, 'visibleWindows': 0}))
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)


if __name__ == '__main__':
    main()
