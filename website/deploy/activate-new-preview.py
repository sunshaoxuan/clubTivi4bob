"""Activate only the static /new/ preview; preserve the running application."""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def site_hashes():
    root = Path("/opt/bobtv/site")
    return {
        str(path.relative_to(root)): digest(path)
        for path in sorted(root.rglob("*"))
        if path.is_file() and "__pycache__" not in path.parts and path.suffix != ".pyc"
    }


def pages():
    result = {}
    for endpoint in ["/", "/downloads", "/diagnostics", "/releases.json"]:
        with urllib.request.urlopen("http://127.0.0.1:8917" + endpoint, timeout=20) as response:
            result[endpoint] = hashlib.sha256(response.read()).hexdigest()
    return result


def run(*args):
    subprocess.run(args, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("release", type=Path)
    args = parser.parse_args()
    release = args.release.resolve()
    if not release.is_relative_to(Path("/opt/bobtv/previews")):
        raise SystemExit("Release must be under /opt/bobtv/previews")
    if not (release / "new/index.html").is_file():
        raise SystemExit("Missing verified preview")
    source = Path(__file__).with_name("nginx-bobtv-new.inc")
    nginx = Path("/etc/nginx/conf.d/bobtv.conf")
    snippet = Path("/etc/nginx/snippets/bobtv-new.inc")
    link = Path("/opt/bobtv/new")
    if link.exists() and not link.is_symlink():
        raise SystemExit("Existing preview path is not a symlink")
    original = nginx.read_bytes()
    previous_snippet = snippet.read_bytes() if snippet.exists() else None
    previous_link = os.readlink(link) if link.is_symlink() else None
    marker = "    include /etc/nginx/snippets/bobtv-new.inc;\n"
    text = original.decode("utf-8")
    needle = "    location / {\n        proxy_pass http://127.0.0.1:8917;"
    if marker not in text:
        if text.count(needle) != 1:
            raise SystemExit("Unexpected Nginx baseline; inspect before activation")
        text = text.replace(needle, marker + "\n" + needle)
    before = site_hashes()
    before_pages = pages()
    backup = release / ("rollback-" + str(int(time.time())))
    backup.mkdir()
    (backup / "bobtv.conf").write_bytes(original)
    if previous_snippet is not None:
        (backup / "bobtv-new.inc").write_bytes(previous_snippet)
    (backup / "previous-link.json").write_text(json.dumps(previous_link))
    try:
        shutil.copyfile(source, snippet)
        nginx.write_text(text, encoding="utf-8")
        temporary = link.with_name("new.next")
        if temporary.exists() or temporary.is_symlink():
            raise RuntimeError("Pending preview switch exists; inspect ownership")
        temporary.symlink_to(release / "new", target_is_directory=True)
        temporary.replace(link)
        run("nginx", "-t")
        run("systemctl", "reload", "nginx")
        if site_hashes() != before or pages() != before_pages:
            raise RuntimeError("Existing site changed during activation; rollback required")
    except BaseException:
        nginx.write_bytes(original)
        if previous_snippet is None:
            snippet.unlink(missing_ok=True)
        else:
            snippet.write_bytes(previous_snippet)
        if link.is_symlink():
            link.unlink()
        if previous_link is not None:
            link.symlink_to(previous_link, target_is_directory=True)
        run("nginx", "-t")
        run("systemctl", "reload", "nginx")
        raise
    receipt = {"release": str(release), "rollback": str(backup), "existing_files_unchanged": len(before), "existing_pages_unchanged": list(before_pages), "api_restarted": False}
    (release / "activation.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
