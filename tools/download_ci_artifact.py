"""Fetch an owned GitHub build artifact through the release mirror host.

The short-lived artifact URL is never logged or persisted. GitHub credentials
remain on the developer machine. Used when local artifact transport stalls.
"""
import argparse
import shlex
import subprocess
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact_id', type=int)
    parser.add_argument('platform', choices=['windows-x64', 'macos-x64', 'macos-arm64'])
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    token = subprocess.check_output(['/Users/shou/.local/bin/gh', 'auth', 'token'], text=True).strip()
    request = urllib.request.Request(
        f'https://api.github.com/repos/sunshaoxuan/clubTivi4bob/actions/artifacts/{args.artifact_id}/zip',
        headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json'})
    opener = urllib.request.build_opener(NoRedirect())
    try:
        opener.open(request, timeout=30)
        raise RuntimeError('Expected artifact redirect')
    except urllib.error.HTTPError as response:
        if response.code != 302:
            raise RuntimeError(f'Artifact service returned {response.code}') from None
        location = response.headers['Location']
    parsed = urlsplit(location)
    if parsed.scheme != 'https' or not parsed.hostname.endswith('.blob.core.windows.net'):
        raise RuntimeError('Unexpected artifact storage host')
    remote = f'/opt/bobtv/staging/artifact-{args.artifact_id}/{args.platform}'
    command = (
        f'mkdir -p {shlex.quote(remote)} && '
        f'curl --fail --silent --show-error --connect-timeout 15 --max-time 300 '
        f'{shlex.quote(location)} -o {shlex.quote(remote + "/artifact.zip")} && '
        f'unzip -q -n {shlex.quote(remote + "/artifact.zip")} -d {shlex.quote(remote + "/files")}')
    connection = ['-i', '/Users/shou/Desktop/Secure/sunsxaws.pem']
    result = subprocess.run(['ssh', *connection, 'root@ccnode.briconbric.com', command])
    if result.returncode:
        raise RuntimeError('Release mirror artifact transfer failed')
    args.output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['scp', *connection, '-r',
        f'root@ccnode.briconbric.com:{remote}/files/.', str(args.output)], check=True)
    print(f'Artifact fetched: {args.platform}')


if __name__ == '__main__':
    main()
