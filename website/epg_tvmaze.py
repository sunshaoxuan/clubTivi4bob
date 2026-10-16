"""Diagnostic TVmaze schedule adapter. No grants, mappings, storage or publication.

API data license: CC BY-SA, https://www.tvmaze.com/api#licensing
Attribution and ShareAlike must be carried into any eventual public derivative.
Episode listings are sparse; this adapter never fills broadcast schedule gaps.
"""
from collections import Counter, defaultdict
from datetime import date, datetime
from email.utils import parsedate_to_datetime
import hashlib
import json
import re
import time
import urllib.error
import urllib.request
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from epg_ingest import EpgError, MAX_COMPRESSED, NoRedirect, decode
from process_channel_inventory import _HTTPHandler, _HTTPSHandler
from source_registry import validate_public_url

API = 'https://api.tvmaze.com/schedule'
LICENSE = 'https://creativecommons.org/licenses/by-sa/4.0/'


def schedule_url(country, day):
    if not isinstance(country, str) or not re.fullmatch(r'[A-Z]{2}', country):
        raise EpgError('invalid_schedule_country')
    if not isinstance(day, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', day):
        raise EpgError('invalid_schedule_date')
    try:
        date.fromisoformat(day)
    except ValueError:
        raise EpgError('invalid_schedule_date') from None
    # Fixed host/path and two encoded scalar parameters only; no user-supplied URL.
    return API + '?country=' + country + '&date=' + day


def fetch_schedule(country, day, opener=None, clock=time.monotonic):
    url = schedule_url(country, day)
    validate_public_url(API)
    opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}),
        NoRedirect(), _HTTPHandler(), _HTTPSHandler())
    started = clock()
    try:
        response = opener.open(urllib.request.Request(url, headers={
            'User-Agent': 'BobTV-EPG-Validator/1.0', 'Accept-Encoding': 'identity'}), timeout=8)
    except urllib.error.HTTPError as exc:
        response = exc
    with response:
        if response.code != 200:
            retry = response.headers.get('Retry-After', '')
            try:
                retry = int(retry) if retry.isdecimal() else max(0, int(parsedate_to_datetime(retry).timestamp() - time.time()))
            except (ValueError, TypeError, OverflowError):
                retry = 0
            raise EpgError('http_' + str(response.code), max(0, retry))
        chunks, size = [], 0
        while True:
            if clock() - started > 32:
                raise EpgError('fetch_deadline')
            chunk = response.read(64 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_COMPRESSED:
                raise EpgError('compressed_size_limit')
            chunks.append(chunk)
        payload = b''.join(chunks)
        return payload, {'sourceUrl': url, 'fetchedAtUtc': int(time.time()),
            'rawSha256': hashlib.sha256(payload).hexdigest(), 'compressedBytes': size,
            'cacheControl': response.headers.get('Cache-Control'),
            'licenseUrl': LICENSE, 'attributionUrl': 'https://www.tvmaze.com/',
            'publicationAllowed': False}


def parse_schedule(payload, country, day, now=None):
    schedule_url(country, day)
    now = int(time.time() if now is None else now)
    try:
        rows = json.loads(decode(payload).decode('utf-8-sig'))
    except (UnicodeError, ValueError):
        raise EpgError('invalid_schedule_json') from None
    if not isinstance(rows, list) or len(rows) > 10000:
        raise EpgError('schedule_row_limit_or_type')
    identities, candidates, rejected, ambiguous = {}, {}, Counter(), set()
    for row in rows:
        try:
            if not isinstance(row, dict) or not isinstance(row.get('show'), dict):
                raise EpgError('invalid_episode')
            show, episode_id = row['show'], row.get('id')
            network = show.get('network')
            if not isinstance(network, dict):
                raise EpgError('not_linear_network')
            context = network.get('country')
            if not isinstance(context, dict) or context.get('code') != country:
                raise EpgError('network_country_mismatch')
            zone = ZoneInfo(context['timezone'])
            network_id, name = network.get('id'), network.get('name')
            if type(network_id) is not int or network_id <= 0 or not isinstance(name, str) or not 1 <= len(name.strip()) <= 256:
                raise EpgError('invalid_network_identity')
            # TVmaze network 72 describes distribution to independent stations,
            # not one linear feed with a reliable common broadcast timetable.
            if network_id == 72 or name.strip().casefold() == 'syndication':
                raise EpgError('nonspecific_syndication_network')
            if type(episode_id) is not int or episode_id <= 0:
                raise EpgError('invalid_episode_identity')
            stamp = row.get('airstamp')
            if not isinstance(stamp, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})', stamp):
                raise EpgError('missing_explicit_timezone')
            start = datetime.fromisoformat(stamp.replace('Z', '+00:00'))
            local = start.astimezone(zone)
            if (row.get('airdate') != day or local.date().isoformat() != day
                    or row.get('airtime') != local.strftime('%H:%M')):
                raise EpgError('source_local_time_mismatch')
            runtime = row.get('runtime')
            if type(runtime) is not int or not 1 <= runtime <= 1440:
                raise EpgError('missing_explicit_episode_runtime')
            title = show.get('name')
            if not isinstance(title, str) or not 1 <= len(title.strip()) <= 512:
                raise EpgError('missing_programme_title')
            key = 'tvmaze-network-' + str(network_id)
            identity = {'id': key, 'originalNetworkId': network_id, 'name': name.strip(),
                'countryCode': country, 'sourceTimezone': context['timezone'],
                'contextVerifiedForCatalog': False}
            if key in identities and identities[key] != identity:
                ambiguous.add(key)
                raise EpgError('network_identity_conflict')
            identities[key] = identity
            starts = int(start.timestamp())
            programme = {'originalChannelId': key, 'title': title.strip(),
                'episodeTitle': row.get('name') if isinstance(row.get('name'), str) else None,
                'startUtc': starts, 'endUtc': starts + runtime * 60,
                'sourceStart': stamp, 'sourceTimezone': context['timezone'],
                'sourceDate': day, 'sourceAirTime': row['airtime'],
                'endBasis': 'start_plus_explicit_episode_runtime', 'sourceRuntimeMinutes': runtime,
                'episodeId': episode_id, 'sourceUrl': 'https://www.tvmaze.com/episodes/' + str(episode_id),
                'licenseUrl': LICENSE, 'attribution': 'TVmaze', 'shareAlikeRequired': True}
            slot = (key, starts)
            if slot in candidates and candidates[slot] != programme:
                candidates[slot] = None
                raise EpgError('conflicting_episode_slot')
            candidates[slot] = programme
        except (EpgError, KeyError, TypeError, ValueError, ZoneInfoNotFoundError) as exc:
            code = str(exc) if isinstance(exc, EpgError) else 'invalid_episode_fields'
            rejected[code] += 1
    programmes, grouped = [], defaultdict(list)
    for (identity, starts), programme in candidates.items():
        grouped[identity].append((starts, programme))
    for key in identities:
        if key in ambiguous:
            continue
        ordered = sorted(grouped[key])
        for index, (_, programme) in enumerate(ordered):
            if programme is None:
                continue
            if index + 1 < len(ordered) and programme['endUtc'] > ordered[index + 1][0]:
                rejected['overlapping_episode_runtime'] += 1
                continue
            programmes.append(programme)
    current = {p['originalChannelId'] for p in programmes if p['startUtc'] <= now < p['endUtc']}
    future = {p['originalChannelId'] for p in programmes if p['startUtc'] > now}
    return {'identities': [v for k, v in identities.items() if k not in ambiguous], 'programmes': programmes,
        'quality': {'inputEpisodes': len(rows), 'acceptedEpisodes': len(programmes),
            'sourceNetworks': len(identities) - len(ambiguous), 'currentNetworks': len(current),
            'futureNetworks': len(future), 'currentAndFutureNetworks': len(current & future),
            'rejected': dict(rejected), 'completeBroadcastSchedule': False,
            'catalogMappingsApproved': 0, 'publicationAllowed': False}}
