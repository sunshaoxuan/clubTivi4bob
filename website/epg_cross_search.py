"""Independent indexed search and reviewed first-party entry points.

Returns leads only. Existing channel identity, permission and freshness
validators remain authoritative. No search snippets are stored.
"""
import json
import os
from pathlib import Path
import signal
import sqlite3
import urllib.error
import urllib.request
from urllib.parse import urlencode

import epg_auto_search as search
from epg_ingest import NoRedirect

BRAVE_MIN_INTERVAL_SECONDS = 20 * 60
BRAVE_ROLLING_DAY_LIMIT = 30
# A 31-day window permits at most 900 + 30 requests, leaving credit headroom.
BRAVE_ROLLING_MONTH_LIMIT = 900
DEEPSEEK_TIMEOUT_SECONDS = 20


def credential():
    directory = os.environ.get('CREDENTIALS_DIRECTORY')
    if directory:
        try:
            with (Path(directory) / 'bobtv-brave-search').open() as f:
                key = f.read(257).strip()
            if 1 <= len(key) <= 256 and key.isascii() and all(c.isalnum() or c in '_-' for c in key):
                return key
        except (OSError, UnicodeError):
            pass
        return None
    return os.environ.get('BOBTV_EPG_BRAVE_SEARCH_KEY')


def reserve_request(conn, now):
    """Reserve before HTTP, including failed calls, in durable rolling windows."""
    with conn:
        conn.execute('BEGIN IMMEDIATE')
        conn.execute('CREATE TABLE IF NOT EXISTS epg_brave_usage (id INTEGER PRIMARY KEY, attempted INTEGER NOT NULL)')
        conn.execute('DELETE FROM epg_brave_usage WHERE attempted<=?', (now - 30 * 86400,))
        newest, daily, monthly = conn.execute('''
            SELECT max(attempted),count(CASE WHEN attempted>? THEN 1 END),count(*)
            FROM epg_brave_usage''', (now - 86400,)).fetchone()
        if ((newest is not None and newest > now - BRAVE_MIN_INTERVAL_SECONDS)
                or daily >= BRAVE_ROLLING_DAY_LIMIT or monthly >= BRAVE_ROLLING_MONTH_LIMIT):
            return False
        conn.execute('INSERT INTO epg_brave_usage(attempted) VALUES(?)', (now,))
        return True


def metered_index(conn, clock):
    def run(query):
        if not credential():
            return 'not_configured', []
        try:
            if not reserve_request(conn, int(clock())):
                return 'budget_deferred', []
        except sqlite3.Error:
            return 'budget_unavailable', []
        return brave(query)
    return run


def brave(query, *, opener=None):
    key = credential()
    if not key:
        return 'not_configured', []
    if opener is None:
        from process_channel_inventory import _HTTPSHandler
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect(), _HTTPSHandler())
    url = 'https://api.search.brave.com/res/v1/web/search?' + urlencode(
        {'q': query, 'count': 5, 'safesearch': 'moderate', 'spellcheck': 'false'})
    try:
        req = urllib.request.Request(url, headers={'X-Subscription-Token': key,
            'Accept': 'application/json', 'Accept-Encoding': 'identity'})
        with opener.open(req, timeout=4) as response:
            if response.geturl() != url or response.code != 200:
                return 'unavailable', []
            data = response.read(262145)
        if len(data) > 262144:
            return 'invalid_response', []
        web = json.loads(data)['web']['results']
        if not isinstance(web, list):
            return 'invalid_response', []
        return 'checked', [r for r in web[:5] if isinstance(r, dict)]
    except urllib.error.HTTPError as exc:
        code = exc.code
        exc.close()
        return ('rate_limited' if code == 429 else
                'authorization_required' if code in (401, 403) else 'unavailable'), []
    except (OSError, ValueError, KeyError, TypeError):
        return 'unavailable', []


def metered_deepseek_index(settings_factory, shared_database, clock):
    def run(query):
        try:
            settings = settings_factory()
            search.validate_settings(settings)
        except (OSError, ValueError, KeyError, TypeError):
            return 'not_configured', []
        try:
            search.reserve_shared_budget(shared_database, int(clock()))
        except search.SearchDeferred:
            return 'budget_deferred', []
        except sqlite3.Error:
            return 'budget_unavailable', []
        return _deepseek(query, settings)
    return run


def _deepseek(query, settings):
    from server_worker import LocalTlsHandler
    handlers = [urllib.request.ProxyHandler({}), NoRedirect()]
    if settings.get('localTls'):
        handlers.append(LocalTlsHandler())
    url = settings['baseUrl'].rstrip('/') + '/responses'
    body = {'model': 'deepseek-v4-pro', 'store': False, 'reasoning': {'effort': 'none'},
            'max_output_tokens': 800, 'tools': [{'type': 'web_search'}], 'tool_choice': 'required',
            'include': ['web_search_call.action.sources'],
            'input': f'用网页搜索工具搜索一次：{query}。仅输出 JSON 对象 '
                     '{"results":[{"title":"网页标题","url":"网页原始网址"}]}，最多 5 条。'
                     '仅列出本次搜索返回的页面。'}
    req = urllib.request.Request(url, json.dumps(body, ensure_ascii=False).encode(), {
        'Authorization': 'Bearer ' + settings['apiKey'], 'Content-Type': 'application/json',
        'Accept': 'application/json', 'Accept-Encoding': 'identity'})

    def deadline(*_):
        raise TimeoutError('bounded_deepseek_search_deadline')

    prior = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(DEEPSEEK_TIMEOUT_SECONDS)
    try:
        with urllib.request.build_opener(*handlers).open(req, timeout=DEEPSEEK_TIMEOUT_SECONDS) as response:
            if response.geturl() != url or response.status != 200:
                return 'unavailable', []
            data = response.read(262145)
        if len(data) > 262144:
            return 'invalid_response', []
        return decode_deepseek(json.loads(data))
    except urllib.error.HTTPError as exc:
        code = exc.code
        exc.close()
        return ('rate_limited' if code == 429 else
                'authorization_required' if code in (401, 402, 403) else 'unavailable'), []
    except OSError:
        return 'unavailable', []
    except (ValueError, KeyError, TypeError, AttributeError):
        return 'invalid_response', []
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, prior)


def decode_deepseek(payload):
    calls = payload['output']
    count = payload.get('usage', {}).get('server_tool_use', {}).get('tool_search', 0)
    searches = [item['action'] for item in calls if item.get('type') == 'web_search_call'
                and item.get('status') == 'completed' and item.get('action', {}).get('type') == 'search']
    if payload.get('status') != 'completed' or type(count) is not int or count < 1 or not searches:
        return 'invalid_response', []
    hits = {}
    for action in searches:
        for hit in action.get('sources') or []:
            if isinstance(hit.get('url'), str) and isinstance(hit.get('title'), str):
                hits[hit['url']] = hit['title']
    if not hits:
        messages = [part for item in calls if item.get('type') == 'message'
                    for part in item.get('content', []) if part.get('type') == 'output_text']
        for part in messages:
            for hit in part.get('annotations') or []:
                if (hit.get('type') == 'url_citation' and isinstance(hit.get('url'), str)
                        and isinstance(hit.get('title'), str)):
                    hits[hit['url']] = hit['title']
        if not hits:
            # Some gateway responses omit citation metadata. The model's URLs
            # are transient matching hints and cannot create a candidate.
            answer = ''.join(part.get('text', '') for part in messages).strip()
            if answer.startswith('```json\n') and answer.endswith('```'):
                answer = answer[8:-3].strip()
            results = json.loads(answer)['results']
            if not isinstance(results, list):
                return 'invalid_response', []
            for hit in results[:5]:
                if isinstance(hit.get('url'), str) and isinstance(hit.get('title'), str):
                    hits.setdefault(hit['url'], hit['title'])
    return 'checked', [{'url': url, 'title': title} for url, title in list(hits.items())[:5]]


def augment(request, evidence, now, *, index=brave, search_engine='brave_web'):
    state, hits = index(request['independentQuery'])
    candidates = list(evidence['candidates'])
    by_url = {r['url']: {**r, 'engines': ['ai_web_search']} for r in candidates}
    extra = []
    corroborated = []
    index_leads = set()
    for hit in hits:
        url = hit.get('url')
        if (search.candidate_allowed(url, request['domains'], request['stage'], request=request)
                and search.candidate_has_target_context(hit, request)):
            index_leads.add(url)
            # Search plans without storage rights permit transient use only.
            # This worker persists its candidates and URLs, so index-only
            # results must never enter that path. Rank independently found
            # candidates with the transient index, then discard its results.
            if url in by_url and url not in corroborated:
                corroborated.append(url)
    context = request['catalogueContext']
    channel = {**context, 'id': request['channelId'],
               'routes': [{'url': u} for u in request['catalogRoutes']]}
    profile = search.scoped_profile(channel, request['categoryPath'])
    if profile and request['stage'] == 'identity':
        for url in profile.get('identityTechnicalPages', []):
            if search.candidate_allowed(url, request['domains'], 'identity', request=request):
                extra.append((url, 'reviewed_operator_entry'))
    independent = []
    for url, engine in extra:
        if url not in by_url:
            by_url[url] = {'url': url, 'checkedAtUtc': now,
                           'state': 'unverified_search_candidate', 'engines': []}
        if engine not in by_url[url]['engines']:
            by_url[url]['engines'].append(engine)
        if url not in independent:
            independent.append(url)
    # Reserve one of the two existing body checks for independent discovery.
    ordering = list(dict.fromkeys(independent[:1] + corroborated
        + [r['url'] for r in candidates] + independent))
    evidence['candidates'] = [by_url[u] for u in ordering[:20]]
    evidence['crossSearch'] = {'searchEngine': search_engine, 'state': state,
        'query': request['independentQuery'], 'indexHits': len(hits),
        'indexTargetMatches': len(index_leads), 'corroboratedLeads': len(corroborated),
        'independentLeads': len(independent), 'focusedRouteSha256': request['focusedRouteSha256']}
    return state
