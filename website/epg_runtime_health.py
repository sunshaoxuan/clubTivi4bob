"""Independent read-only EPG runtime watchdog. Never fetch programme upstreams.

The only writes are an atomic private health receipt. No migrations, grants,
mapping changes, service restarts or publication are performed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import time
import urllib.request

from epg_ingest import EpgError, NoRedirect
from epg_coverage import summarize
from epg_store import NODES, active_manifest
from process_channel_inventory import _HTTPHandler, _HTTPSHandler

WORKERS = {'validator': 600, 'discovery': 600, 'schedules': 600,
           'publisher': 600, 'source-discovery': 1200}
PROPERTIES = ('Id', 'ActiveState', 'UnitFileState', 'Result', 'ExecMainStatus',
              'ExecMainStartTimestampMonotonic', 'ExecMainExitTimestampMonotonic')


def units():
    names = ['bobtv-epg-' + name + suffix for name in WORKERS for suffix in ('.service', '.timer')]
    command = ['systemctl', 'show', *names]
    for prop in PROPERTIES:
        command.extend(['-p', prop])
    result = subprocess.run(command, capture_output=True, text=True, timeout=8, check=True)
    if len(result.stdout) > 65536:
        raise ValueError('unit_response_limit')
    return {row['Id']: row for block in result.stdout.strip().split('\n\n')
            if (row := dict(line.split('=', 1) for line in block.splitlines() if '=' in line)) and 'Id' in row}


def check_units(values, uptime):
    issues = []
    for name, limit in WORKERS.items():
        base = 'bobtv-epg-' + name
        timer, service = values.get(base + '.timer', {}), values.get(base + '.service', {})
        if timer.get('ActiveState') != 'active' or timer.get('UnitFileState') not in {'enabled', 'enabled-runtime'}:
            issues.append({'code': 'timer_not_enabled_active', 'worker': name})
        if service.get('Result') != 'success' or service.get('ExecMainStatus') != '0':
            issues.append({'code': 'worker_last_run_failed', 'worker': name})
        try:
            start = int(service.get('ExecMainStartTimestampMonotonic', '0')) / 1000000
            if start > uptime + 5 or (start <= 0 and uptime > limit) or (start > 0 and uptime - start > limit):
                issues.append({'code': 'worker_stalled', 'worker': name})
        except (ValueError, TypeError):
            issues.append({'code': 'worker_timestamp_invalid', 'worker': name})
    return issues


def read_node(node):
    if node not in NODES:
        raise ValueError('unapproved_node')
    url = node + '/api/v1/epg/manifest'
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), _HTTPHandler(), _HTTPSHandler())
    request = urllib.request.Request(url, headers={'User-Agent': 'BobTV-EPG-Health/1.0',
        'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache, no-store', 'Pragma': 'no-cache'})
    with opener.open(request, timeout=12) as response:
        if response.status != 200 or response.geturl() != url:
            raise ValueError('node_manifest_unavailable')
        raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError('node_manifest_size_limit')
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError('node_manifest_invalid')
    return data


def inspect(directory, *, now=None, uptime=None, unit_reader=units, node_reader=read_node, previous=None):
    now = int(time.time() if now is None else now)
    uptime = time.monotonic() if uptime is None else uptime
    out = {'schemaVersion': 1, 'checkedAtUtc': now, 'state': 'healthy', 'issues': [],
           'programmeUpstreamRequests': 0, 'databaseWritten': False, 'servicesRestarted': False}
    try:
        out['issues'].extend(check_units(unit_reader(), uptime))
    except (OSError, ValueError, subprocess.SubprocessError):
        out['issues'].append({'code': 'unit_inspection_failed'})
    path = Path(directory) / 'epg.sqlite3'
    if not path.is_file() or path.is_symlink():
        out['issues'].append({'code': 'database_unavailable'})
    else:
        try:
            with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2) as db:
                db.row_factory = sqlite3.Row
                started = time.monotonic()
                db.set_progress_handler(lambda: int(time.monotonic() - started > 8), 10000)
                db.execute('BEGIN')
                expected = active_manifest(db)
                out['coverage'] = summarize(db, now, Path(directory) / 'public')
                out['sources'] = [dict(row) for row in db.execute('''SELECT id,state,last_success,last_failure,next_retry,last_error,failures
                  FROM source_health WHERE id IN (SELECT source_id FROM epg_data_grants WHERE revoked=0)
                  AND id IN (SELECT a.source_id FROM epg_mapping_approvals a
                    JOIN discovery_jobs j ON j.channel_id=a.channel_id AND j.active=1 WHERE a.revoked=0)
                  ORDER BY id LIMIT 201''')]
                for source in out['sources']:
                    if source['last_error'] and not re.fullmatch(r'[a-z0-9_:-]{1,100}', source['last_error']):
                        source['last_error'] = 'redacted_unstructured_error'
                    if source['state'] == 'superseded':
                        out['issues'].append({'code': 'approved_source_superseded', 'sourceId': source['id']})
                    elif source['next_retry'] < now - 600:
                        out['issues'].append({'code': 'approved_source_refresh_overdue', 'sourceId': source['id']})
                    if source['failures'] >= 3:
                        out['issues'].append({'code': 'approved_source_repeated_failures', 'sourceId': source['id']})
                if len(out['sources']) > 200:
                    out['sources'] = out['sources'][:200]
                    out['issues'].append({'code': 'source_health_limit'})
                db.rollback()
            coverage = out['coverage']
            if coverage.get('coverageError') or not coverage.get('publishedSnapshotVerifiedLocally'):
                out['issues'].append({'code': 'public_snapshot_not_verified'})
            count = coverage['publishedCurrentAndFutureChannels']
            if count == 0:
                out['issues'].append({'code': 'no_current_and_future_public_coverage'})
            if (isinstance(previous, dict) and type(previous.get('checkedAtUtc')) is int
                    and isinstance(previous.get('coverage'), dict)
                    and 0 <= now - previous['checkedAtUtc'] <= 3600):
                old = previous.get('coverage', {}).get('publishedCurrentAndFutureChannels')
                if type(old) is int and old > count:
                    out['issues'].append({'code': 'public_coverage_declined', 'previous': old, 'current': count})
            out['nodes'] = []
            for node in NODES:
                try:
                    actual = node_reader(node)
                    if not isinstance(actual, dict):
                        raise ValueError('node_manifest_invalid')
                    matched = expected is not None and all(actual.get(key) == expected.get(key) for key in
                        ('version', 'sha256', 'snapshotUrl', 'compressedBytes', 'channelCount', 'programmeCount'))
                    version = actual.get('version')
                    version = version if isinstance(version, str) and re.fullmatch(r'epg-[a-f0-9]{64}', version) else None
                    out['nodes'].append({'node': node, 'version': version, 'matchesAuthority': matched})
                except (OSError, ValueError, TypeError, EpgError):
                    out['nodes'].append({'node': node, 'matchesAuthority': False, 'error': 'node_manifest_check_failed'})
            # Publication can advance during network checks; do not mistake that
            # expected race for a persistent split-brain or overwrite its pointer.
            with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2) as db:
                db.row_factory = sqlite3.Row
                fresh = active_manifest(db)
            changed = (fresh or {}).get('version') != (expected or {}).get('version')
            out['authorityChangedDuringCheck'] = changed
            if changed:
                out['issues'].append({'code': 'publication_changed_retry_next_check'})
            elif any(not node['matchesAuthority'] for node in out['nodes']):
                out['issues'].append({'code': 'node_version_or_manifest_mismatch'})
        except (sqlite3.Error, OSError, ValueError, TypeError, KeyError, EpgError):
            out['issues'].append({'code': 'database_or_coverage_inspection_failed'})
    if out['issues']:
        out['state'] = 'degraded'
    return out


def save(directory, report):
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError('unsafe_health_directory')
    raw = (json.dumps(report, ensure_ascii=False, sort_keys=True) + '\n').encode()
    fd, name = tempfile.mkstemp(prefix='.runtime-health-', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, directory / 'runtime-health.json')
        directory_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', default='/var/lib/bobtv/epg')
    args = parser.parse_args()
    previous = None
    try:
        path = Path(args.directory) / 'runtime-health.json'
        if not path.is_symlink() and path.stat().st_size <= 262144:
            previous = json.loads(path.read_text())
            if not isinstance(previous, dict):
                previous = None
    except (OSError, ValueError):
        pass
    report = inspect(args.directory, previous=previous)
    save(args.directory, report)
    print(json.dumps(report, ensure_ascii=False))
    return int(report['state'] != 'healthy')


if __name__ == '__main__':
    raise SystemExit(main())
