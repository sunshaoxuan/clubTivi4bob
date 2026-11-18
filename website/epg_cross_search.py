"""Independent indexed search and reviewed first-party entry points.

Returns leads only. Existing channel identity, permission and freshness
validators remain authoritative. No search snippets are stored.
"""
import json
import os
import urllib.error
import urllib.request
from urllib.parse import urlencode

import epg_auto_search as search
from epg_ingest import NoRedirect


def brave(query, *, opener=None):
    key = os.environ.get('BOBTV_EPG_BRAVE_SEARCH_KEY')
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


def augment(request, evidence, now, *, index=brave):
    state, hits = index(request['independentQuery'])
    candidates = list(evidence['candidates'])
    by_url = {r['url']: {**r, 'engines': ['ai_web_search']} for r in candidates}
    extra = []
    for hit in hits:
        url = hit.get('url')
        if (search.candidate_allowed(url, request['domains'], request['stage'], request=request)
                and search.candidate_has_target_context(hit, request)):
            extra.append((url, 'brave_web'))
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
    ordering = list(dict.fromkeys(independent[:1] + [r['url'] for r in candidates] + independent))
    evidence['candidates'] = [by_url[u] for u in ordering[:20]]
    evidence['crossSearch'] = {'searchEngine': 'brave_web', 'state': state,
        'query': request['independentQuery'], 'indexHits': len(hits),
        'independentLeads': len(independent), 'focusedRouteSha256': request['focusedRouteSha256']}
    return state
