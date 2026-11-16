"""Offline monitoring acceptance with isolated DB and synthetic schedules."""
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_runtime_health as health
import epg_store as store
from epg_ingest import database
from test_epg_schedule_worker import setup, NOW
import epg_schedule_worker as worker


def healthy_units():
    result = {}
    for name in health.WORKERS:
        base = 'bobtv-epg-' + name
        result[base + '.timer'] = {'ActiveState': 'active', 'UnitFileState': 'enabled'}
        result[base + '.service'] = {'ActiveState': 'inactive', 'Result': 'success',
            'ExecMainStatus': '0', 'ExecMainStartTimestampMonotonic': '1000000000'}
    return result


@pytest.fixture
def live(tmp_path):
    setup(tmp_path)
    worker.run(tmp_path, now=NOW)
    with database(tmp_path) as conn:
        public = tmp_path / 'public'
        store.publish(conn, public, now=NOW,
            node_fetcher=lambda url: (public / 'snapshots' / url.rsplit('/', 1)[-1]).read_bytes())
        manifest = store.active_manifest(conn)
    return tmp_path, manifest


def inspect(live, **kwargs):
    directory, manifest = live
    return health.inspect(directory, now=NOW, uptime=1001,
        unit_reader=kwargs.pop('unit_reader', healthy_units),
        node_reader=kwargs.pop('node_reader', lambda _: manifest), **kwargs)


def test_healthy_idle_oneshots_are_not_failed(live):
    report = inspect(live)
    assert report['state'] == 'healthy' and report['issues'] == []
    assert report['coverage']['publishedCurrentAndFutureChannels'] == 1
    assert report['programmeUpstreamRequests'] == 0


@pytest.mark.parametrize('fault,expected', [('disabled', 'timer_not_enabled_active'),
    ('failed', 'worker_last_run_failed'), ('stale', 'worker_stalled'), ('future', 'worker_stalled')])
def test_stopped_or_stalled_task_is_visible(live, fault, expected):
    values = healthy_units()
    timer, service = values['bobtv-epg-validator.timer'], values['bobtv-epg-validator.service']
    if fault == 'disabled':
        timer['UnitFileState'] = 'disabled'
    elif fault == 'failed':
        service.update(Result='timeout', ExecMainStatus='9')
    else:
        service['ExecMainStartTimestampMonotonic'] = '1000000' if fault == 'stale' else '3000000000'
    report = inspect(live, unit_reader=lambda: values)
    assert {'code': expected, 'worker': 'validator'} in report['issues']


@pytest.mark.parametrize('actual', [None, {}, {'version': 'different'}])
def test_two_node_mismatch_or_invalid_response_is_visible(live, actual):
    report = inspect(live, node_reader=lambda _: actual)
    assert report['state'] == 'degraded'
    assert any(x['code'] == 'node_version_or_manifest_mismatch' for x in report['issues'])


def test_node_timeout_has_safe_error_and_keeps_db(live):
    def fail(_):
        raise OSError('secret must not be retained')
    report = inspect(live, node_reader=fail)
    assert 'secret' not in json.dumps(report)
    assert report['state'] == 'degraded'


def test_recent_coverage_drop_is_reported(live):
    report = inspect(live, previous={'checkedAtUtc': NOW - 600,
        'coverage': {'publishedCurrentAndFutureChannels': 2}})
    assert {'code': 'public_coverage_declined', 'previous': 2, 'current': 1} in report['issues']


@pytest.mark.parametrize('late,failures,expected', [(True, 0, 'approved_source_refresh_overdue'),
    (False, 3, 'approved_source_repeated_failures')])
def test_source_refresh_stall_and_repeated_failure_are_visible(live, late, failures, expected):
    directory, _ = live
    with database(directory) as conn:
        conn.execute('UPDATE source_health SET next_retry=?,failures=?',
            (NOW - 601 if late else NOW + 900, failures))
        conn.commit()
    assert any(x['code'] == expected for x in inspect(live)['issues'])


def test_single_transient_source_failure_keeps_valid_coverage(live):
    directory, _ = live
    with database(directory) as conn:
        conn.execute("UPDATE source_health SET state='failed',failures=1,next_retry=?", (NOW + 900,))
        conn.commit()
    assert inspect(live)['state'] == 'healthy'


def test_malformed_previous_report_does_not_hide_current_health(live):
    assert inspect(live, previous={'checkedAtUtc': 'bad', 'coverage': None})['state'] == 'healthy'


def test_expired_programmes_are_not_healthy(live):
    directory, manifest = live
    report = health.inspect(directory, now=NOW + 20000, uptime=1001,
        unit_reader=healthy_units, node_reader=lambda _: manifest)
    assert report['state'] == 'degraded'
    assert {'code': 'no_current_and_future_public_coverage'} in report['issues']


def test_database_and_programme_cache_are_read_only(live):
    directory, _ = live
    paths = [directory / 'epg.sqlite3', *list((directory / 'payload-cache').iterdir())]
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    assert inspect(live)['databaseWritten'] is False
    assert before == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def test_missing_database_does_not_create_one(tmp_path):
    report = health.inspect(tmp_path, now=NOW, uptime=1001, unit_reader=healthy_units,
        node_reader=lambda _: pytest.fail('no network without DB'))
    assert {'code': 'database_unavailable'} in report['issues']
    assert not (tmp_path / 'epg.sqlite3').exists()


def test_atomic_receipt_is_private_and_never_follows_destination_symlink(tmp_path):
    outside = tmp_path / 'preserved'
    outside.write_text('unchanged')
    (tmp_path / 'runtime-health.json').symlink_to(outside)
    health.save(tmp_path, {'state': 'healthy'})
    assert outside.read_text() == 'unchanged'
    dest = tmp_path / 'runtime-health.json'
    assert not dest.is_symlink()
    assert dest.stat().st_mode & 0o777 == 0o600
    assert json.loads(dest.read_text()) == {'state': 'healthy'}


@pytest.mark.parametrize('oversized', [False, True])
def test_manifest_fetch_is_bounded_and_bypasses_cache(monkeypatch, oversized):
    seen = {}
    class Response:
        status = 200
        def __enter__(self):
            return self
        def __exit__(self, *_):
            pass
        def geturl(self):
            return health.NODES[0] + '/api/v1/epg/manifest'
        def read(self, size):
            assert size == 65537
            return b'x' * size if oversized else b'{"version":null}'
    class Opener:
        def open(self, request, timeout):
            seen.update(timeout=timeout, headers={k.lower(): v for k, v in request.header_items()})
            return Response()
    monkeypatch.setattr(health.urllib.request, 'build_opener', lambda *_: Opener())
    if oversized:
        with pytest.raises(ValueError, match='size_limit'):
            health.read_node(health.NODES[0])
    else:
        assert health.read_node(health.NODES[0]) == {'version': None}
    assert seen['timeout'] == 12
    assert seen['headers']['cache-control'] == 'no-cache, no-store'
    assert seen['headers']['pragma'] == 'no-cache'


def test_manifest_fetch_rejects_arbitrary_host():
    with pytest.raises(ValueError, match='unapproved_node'):
        health.read_node('http://127.0.0.1')
