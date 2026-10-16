"""Read-only coverage of approved rows and the actual active immutable snapshot.

Candidate matches, source-level episode counts and unactivated snapshots are
never public coverage. All queries share one SQLite read snapshot.
"""
from collections import defaultdict
import hashlib
import json
from pathlib import Path

import epg_store as store
from epg_ingest import EpgError, decode


def _expected_provenance(mapping):
    return {'sourceUrl': mapping['source_url'], 'dataLicense': mapping['data_license'],
        'dataLicenseEvidenceUrl': mapping['evidence_url'],
        'mappingEvidence': json.loads(mapping['evidence']), 'confidence': mapping['confidence'],
        'originalChannelNames': json.loads(mapping['names_json'])}


def _channel(mapping):
    return {**json.loads(mapping['payload']), 'sourceId': mapping['source_id'],
        'originalChannelId': mapping['original_id'],
        'catalogIdentityHash': mapping['catalog_identity_hash'], 'confidence': mapping['confidence']}


def _published(conn, directory, mappings, now, outcome):
    manifest = store.active_manifest(conn)
    if manifest is None:
        return
    outcome['publishedEpgVersion'] = manifest['version']
    path = Path(directory) / 'snapshots' / (manifest['sha256'] + '.json.gz')
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
        raise EpgError('coverage_snapshot_unavailable')
    if path.stat().st_size != manifest['compressedBytes']:
        raise EpgError('coverage_snapshot_checksum_mismatch')
    with path.open('rb') as stream:
        raw = stream.read(8 * 1024 * 1024 + 1)
    if len(raw) != manifest['compressedBytes'] or hashlib.sha256(raw).hexdigest() != manifest['sha256']:
        raise EpgError('coverage_snapshot_checksum_mismatch')
    payload = json.loads(decode(raw))
    if (not isinstance(payload, dict) or set(payload) != {'schemaVersion', 'version', 'channels', 'programmes', 'dataAttributions'}
            or payload['schemaVersion'] != 1 or payload['version'] != manifest['version']
            or not isinstance(payload['channels'], list) or len(payload['channels']) != manifest['channelCount']
            or not isinstance(payload['programmes'], list) or len(payload['programmes']) != manifest['programmeCount']
            or not isinstance(payload['dataAttributions'], list)):
        raise EpgError('coverage_snapshot_content_mismatch')
    core = {key: value for key, value in payload.items() if key != 'version'}
    if payload['version'] != 'epg-' + store.fingerprint(core):
        raise EpgError('coverage_snapshot_content_mismatch')
    channels = {item['id']: item for item in payload['channels']}
    credits = {item['sourceId']: {key: value for key, value in item.items() if key != 'sourceId'}
        for item in payload['dataAttributions']}
    if len(channels) != len(payload['channels']) or len(credits) != len(payload['dataAttributions']):
        raise EpgError('coverage_snapshot_content_mismatch')
    grouped = defaultdict(list)
    for programme in payload['programmes']:
        if programme['channelId'] not in channels:
            raise EpgError('coverage_snapshot_content_mismatch')
        grouped[programme['channelId']].append(programme)
    count = 0
    for identity, mapping in mappings.items():
        if channels.get(identity) != _channel(mapping):
            continue
        credit = conn.execute('SELECT metadata FROM epg_data_attributions WHERE source_id=?',
            (mapping['source_id'],)).fetchone()
        if credits.get(mapping['source_id']) != (json.loads(credit[0]) if credit else None):
            continue
        rows = grouped[identity]
        expected = _expected_provenance(mapping)
        if not rows or any(not isinstance(row.get('provenance'), dict)
                or row.get('sourceId') != mapping['source_id']
                or row.get('originalChannelId') != mapping['original_id']
                or type(row.get('startUtc')) is not int or type(row.get('stopUtc')) is not int
                or row['stopUtc'] <= row['startUtc']
                or any(row['provenance'].get(key) != value for key, value in expected.items()) for row in rows):
            continue
        ordered = sorted(rows, key=lambda row: row['startUtc'])
        if any(a['stopUtc'] > b['startUtc'] for a, b in zip(ordered, ordered[1:])):
            continue
        count += int(any(row['startUtc'] <= now < row['stopUtc'] for row in rows)
            and any(row['startUtc'] > now for row in rows))
    outcome['publishedCurrentAndFutureChannels'] = count
    outcome['publishedSnapshotVerifiedLocally'] = True


def summarize(conn, now, public_directory=None):
    outcome = {'catalogChannels': 0, 'verifiedMappings': 0, 'currentAndFutureChannels': 0,
        'publishedCurrentAndFutureChannels': 0, 'publishedEpgVersion': None,
        'publishedSnapshotVerifiedLocally': False, 'coverageError': None}
    conn.execute('SAVEPOINT epg_coverage_read')
    try:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'discovery_jobs' in tables:
            outcome['catalogChannels'] = conn.execute('SELECT count(*) FROM discovery_jobs WHERE active=1').fetchone()[0]
        if not {'epg_mapping_approvals', 'epg_programmes', 'epg_data_grants', 'epg_data_attributions'} <= tables:
            return outcome
        mappings = {}
        for row in conn.execute('SELECT channel_id FROM epg_mapping_approvals WHERE revoked=0').fetchall():
            try:
                mapping = store._approved(conn, row['channel_id'])
                if store.reviewed_data_use(conn, mapping['source_id']):
                    mappings[row['channel_id']] = mapping
            except (EpgError, ValueError, TypeError, KeyError):
                continue
        outcome['verifiedMappings'] = len(mappings)
        try:
            eligible = store.build_payload(conn, now)
            outcome['currentAndFutureChannels'] = sum(item['id'] in mappings for item in eligible['channels'])
        except EpgError as error:
            if str(error) != 'no_publishable_current_future_data':
                raise
        if public_directory is not None:
            _published(conn, public_directory, mappings, now, outcome)
        return outcome
    except (EpgError, OSError, ValueError, TypeError, KeyError):
        outcome['coverageError'] = 'coverage_evidence_invalid'
        outcome['publishedCurrentAndFutureChannels'] = 0
        outcome['publishedSnapshotVerifiedLocally'] = False
        return outcome
    finally:
        conn.execute('ROLLBACK TO epg_coverage_read')
        conn.execute('RELEASE epg_coverage_read')
