"""Synthetic fixtures only; no real data grants or public publications."""
import fcntl
import json
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_ingest as epg
import epg_publish_worker as publisher
import epg_schedule_worker as ingestion
from test_epg_schedule_worker import NOW, SOURCE, setup, body, public_fetch, active


def test_missing_database_creates_no_database_or_network_calls(tmp_path):
    assert publisher.run(tmp_path, now=NOW)['state'] == 'waiting_for_database'
    assert not list(tmp_path.iterdir())


def test_unapproved_or_empty_data_never_fetches_or_activates(tmp_path):
    setup(tmp_path, approve=False)
    result = publisher.run(tmp_path, now=NOW, node_fetcher=lambda _: pytest.fail('no HTTP without grants'))
    assert result['state'] == 'waiting_for_approved_programmes'
    assert result['failures'] == 0 and result['nextRetryAt'] == 0
    assert result['activeVersion'] is None and not result['published']
    assert active(tmp_path) is None
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM epg_publisher_attempts').fetchone()[0] == 1
        assert conn.execute('SELECT count(*) FROM epg_publication_audit').fetchone()[0] == 0


def test_two_automatic_fixture_versions_and_unchanged_no_redownload(tmp_path):
    setup(tmp_path)
    ingestion.run(tmp_path, now=NOW)
    calls = []
    first = publisher.run(tmp_path, now=NOW, node_fetcher=public_fetch(tmp_path, calls))
    unchanged = publisher.run(tmp_path, now=NOW + 1, node_fetcher=lambda _: pytest.fail('unchanged must not download'))
    assert first['state'] == 'published' and unchanged['state'] == 'unchanged'
    epg.probe_batch(tmp_path, [SOURCE], NOW + 900, lambda _: (body('second'), {}))
    ingestion.run(tmp_path, now=NOW + 900)
    second = publisher.run(tmp_path, now=NOW + 900, node_fetcher=public_fetch(tmp_path, calls))
    assert second['published'] and first['version'] != second['version']
    assert len(calls) == 4 and all(any(url.startswith(node + '/api/v1/epg/snapshots/')
        for node in publisher.store.NODES) for url in calls)
    assert active(tmp_path)['version'] == second['version']


@pytest.mark.parametrize('kind', ['timeout', 'checksum', 'rate_limit', 'unsafe_error'])
def test_node_failure_keeps_pointer_and_backoff_recovers(tmp_path, kind):
    setup(tmp_path)
    ingestion.run(tmp_path, now=NOW)
    first = publisher.run(tmp_path, now=NOW, node_fetcher=public_fetch(tmp_path, []))
    epg.probe_batch(tmp_path, [SOURCE], NOW + 900, lambda _: (body('second'), {}))
    ingestion.run(tmp_path, now=NOW + 900)
    def broken(url):
        if kind == 'rate_limit':
            raise epg.EpgError('http_429', 900)
        if kind == 'unsafe_error':
            raise epg.EpgError('secret unsafe upstream body')
        if kind == 'timeout':
            raise TimeoutError('not exposed')
        return b'wrong'
    failed = publisher.run(tmp_path, now=NOW + 900, node_fetcher=broken)
    delay = 900 if kind == 'rate_limit' else 60
    assert failed['state'] == 'failed' and failed['nextRetryAt'] == NOW + 900 + delay
    assert 'secret' not in json.dumps(failed) and 'not exposed' not in json.dumps(failed)
    assert active(tmp_path)['version'] == first['version']
    waiting = publisher.run(tmp_path, now=NOW + 900 + delay - 1, node_fetcher=lambda _: pytest.fail('backoff HTTP'))
    assert waiting['state'] == 'waiting_for_retry'
    recovered = publisher.run(tmp_path, now=NOW + 900 + delay, node_fetcher=public_fetch(tmp_path, []))
    assert recovered['state'] == 'published' and recovered['failures'] == 0
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM epg_publisher_attempts').fetchone()[0] == 3


def test_worker_lock_and_interrupted_lease_resume_preserve_audit(tmp_path):
    setup(tmp_path)
    ingestion.run(tmp_path, now=NOW)
    with (tmp_path / 'publisher-worker.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert publisher.run(tmp_path, now=NOW)['state'] == 'waiting_for_lock'
    with epg.database(tmp_path) as conn:
        publisher.migrate(conn)
        with conn:
            conn.execute("INSERT INTO epg_publisher_attempts(started_at,state,next_retry) VALUES(?,'publishing',?)", (NOW, NOW + 120))
            conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)',
                ('publisher', json.dumps({'failures': 0, 'nextRetryAt': NOW + 120, 'state': 'publishing'})))
    assert publisher.run(tmp_path, now=NOW + 119)['state'] == 'waiting_for_retry'
    assert publisher.run(tmp_path, now=NOW + 120, node_fetcher=public_fetch(tmp_path, []))['published']
    with epg.database(tmp_path) as conn:
        rows = conn.execute('SELECT state,error_code FROM epg_publisher_attempts ORDER BY id').fetchall()
        assert [tuple(row) for row in rows] == [('interrupted', 'worker_interrupted'), ('published', None)]


def test_invalid_retry_checkpoint_is_not_reset(tmp_path):
    setup(tmp_path)
    with epg.database(tmp_path) as conn:
        conn.execute('INSERT OR REPLACE INTO epg_checkpoints VALUES(?,?)', ('publisher', '{bad'))
        conn.commit()
    with pytest.raises(epg.EpgError, match='publisher_checkpoint_invalid'):
        publisher.run(tmp_path, now=NOW)
    with epg.database(tmp_path) as conn:
        assert conn.execute("SELECT value FROM epg_checkpoints WHERE name='publisher'").fetchone()[0] == '{bad'
