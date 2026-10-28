"""Offline scheduling fixtures; category labels never establish identity."""
import copy
import json
from pathlib import Path
import sqlite3
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parents[1]))
import epg_auto_search_worker as worker
import epg_channel_research as queue
from test_epg_channel_research import channel, NOW


REGIONAL_PATH = ['国际', '台湾']
FOREIGN_PATH = ['国际', '其他']


@pytest.fixture
def conn():
    value = sqlite3.connect(':memory:')
    value.row_factory = sqlite3.Row
    worker.migrate(value)
    yield value
    value.close()


@pytest.mark.parametrize('label', ['中国', '中國', '香港', '澳门', '澳門', '台湾', '台灣', '臺灣'])
@pytest.mark.parametrize('playable', [False, True])
def test_exact_public_regional_category_is_only_a_scheduling_hint(label, playable):
    target = channel(country=None)
    target['routes'][0]['lastPlayableAt'] = 'fixture-public-check' if playable else None
    before = copy.deepcopy(target)
    assert worker.research_priority(target, ['国际', label]) == int(not playable)
    assert target == before and target['countryCode'] is None


@pytest.mark.parametrize('country', [None, ''])
def test_missing_country_has_same_regional_scheduling_without_filling_country(country):
    target = channel(country=country)
    assert worker.research_priority(target, REGIONAL_PATH) == 0
    assert target['countryCode'] == country


@pytest.mark.parametrize('country', ['FR', 'GB', 'US', 'RU', 'ZZ'])
def test_explicit_nonregional_country_is_not_overridden_by_category(country):
    assert worker.research_priority(channel(country=country), REGIONAL_PATH) == 10


@pytest.mark.parametrize('country', ['CN', 'HK', 'MO', 'TW'])
def test_explicit_regional_country_keeps_original_priority(country):
    assert worker.research_priority(channel(country=country), FOREIGN_PATH) == 0


@pytest.mark.parametrize('path', [None, [], ['国际'], ['台湾综艺'], ['非香港'], ['Taiwan'], ['TW'], ['台语节目']])
def test_no_substring_name_or_unreviewed_alias_inference(path):
    target = channel(name='台湾电视 Fixture', country=None)
    target['regionCode'] = 'TW'
    target['routes'][0]['url'] = 'https://taiwan.example.org/fixture.m3u8'
    assert worker.research_priority(target, path) == 10


def select(conn, targets, paths, *, now=NOW, protected=None, handled=None):
    return worker.choose(conn, {'version': 'fixture-v1'}, targets, paths,
                         protected or set(), now, handled or set())


def snapshot(conn):
    return {table: [dict(row) for row in conn.execute('SELECT * FROM ' + table)]
            for table in ('epg_channel_research_jobs', 'epg_channel_research_audit')}


def targets_and_paths():
    targets = [channel(identity='a-foreign', country='FR'),
               channel(identity='z-regional', name='Fixture Regional Main', country=None)]
    return targets, {'a-foreign': FOREIGN_PATH, 'z-regional': REGIONAL_PATH}


def test_new_single_target_selection_uses_hint_without_identity_approval(conn):
    targets, paths = targets_and_paths()
    row = select(conn, targets, paths)
    assert row['channel_id'] == 'z-regional'
    assert row['state'] == 'pending_identity' and row['identity_evidence'] is None
    assert row['attempts'] == 0 and row['lease_until'] == 0
    assert json.loads(row['payload'])['countryCode'] is None
    assert conn.execute('SELECT count(*) FROM epg_channel_research_jobs').fetchone()[0] == 1


def seed(conn, targets, paths):
    for target in targets:
        queue.enqueue(conn, target, 'fixture-v1', paths[target['id']], NOW)


def test_retained_old_priority_is_recomputed_without_any_queue_or_audit_write(conn):
    targets, paths = targets_and_paths()
    seed(conn, targets, paths)
    before = snapshot(conn)
    assert before['epg_channel_research_jobs'][1]['priority'] == 10
    assert select(conn, targets, paths)['channel_id'] == 'z-regional'
    assert snapshot(conn) == before


def test_future_floor_survives_and_only_due_target_is_selected(conn):
    targets, paths = targets_and_paths()
    seed(conn, targets, paths)
    conn.execute('UPDATE epg_channel_research_jobs SET next_retry=?,attempts=7 WHERE channel_id=?',
                 (NOW + 21600, 'z-regional'))
    conn.commit()
    before = snapshot(conn)
    assert select(conn, targets, paths)['channel_id'] == 'a-foreign'
    assert select(conn, targets, paths, now=NOW + 21600)['channel_id'] == 'z-regional'
    assert snapshot(conn) == before


@pytest.mark.parametrize('guard', ['lease', 'inactive', 'protected', 'handled'])
def test_hint_never_bypasses_existing_guards(conn, guard):
    targets, paths = targets_and_paths()
    seed(conn, targets, paths)
    if guard == 'lease':
        conn.execute('UPDATE epg_channel_research_jobs SET lease_until=? WHERE channel_id=?',
                     (NOW + 120, 'z-regional'))
    if guard == 'inactive':
        conn.execute('UPDATE epg_channel_research_jobs SET active=0 WHERE channel_id=?', ('z-regional',))
    conn.commit()
    before = snapshot(conn)
    kwargs = {guard: {'z-regional'}} if guard in ('protected', 'handled') else {}
    assert select(conn, targets, paths, **kwargs)['channel_id'] == 'a-foreign'
    assert snapshot(conn) == before


def test_reviewed_identity_keeps_priority_within_same_regional_bucket(conn):
    targets = [channel(identity='a-unreviewed', country='CN'), channel(identity='z-reviewed', country='TW')]
    paths = {target['id']: REGIONAL_PATH for target in targets}
    seed(conn, targets, paths)
    conn.execute('UPDATE epg_channel_research_jobs SET identity_evidence=? WHERE channel_id=?',
                 (json.dumps({'fixture': 'already-reviewed'}), 'z-reviewed'))
    conn.commit()
    before = snapshot(conn)
    assert select(conn, targets, paths)['channel_id'] == 'z-reviewed'
    assert snapshot(conn) == before


def test_retained_playability_score_survives_category_bucket_adjustment(conn):
    targets = [channel(identity='a-retained-offline', name='Fixture Radio', country=None),
               channel(identity='z-retained-playable', country=None)]
    paths = {target['id']: REGIONAL_PATH for target in targets}
    seed(conn, targets, paths)
    conn.execute('UPDATE epg_channel_research_jobs SET priority=11 WHERE channel_id=?',
                 ('a-retained-offline',))
    conn.commit()
    before = snapshot(conn)
    assert select(conn, targets, paths)['channel_id'] == 'z-retained-playable'
    assert snapshot(conn) == before


def test_selection_retains_strict_identity_gate_for_category_hint(conn):
    from epg_ingest import EpgError
    targets, paths = targets_and_paths()
    selected = select(conn, targets, paths)
    claim = queue.claim_one(conn, NOW, channel_id=selected['channel_id'])
    with pytest.raises(EpgError, match='research_identity_before_search'):
        queue.record_search(conn, claim, ['Fixture Regional Main XMLTV'], [], 'not_found', NOW + 1)
    assert json.loads(claim['payload'])['countryCode'] is None
