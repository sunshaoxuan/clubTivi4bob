"""Retrieve existing subtitle files. Never invoke translation/generation actions."""
import hashlib
from subtitle_io import pool as download_pool
from subtitle_edition import chinese_script, pair_reference, transcript_fingerprint
import html
from scrapling.parser import Selector
import json
from pathlib import Path
import re
from urllib.parse import urlencode, urljoin, urlsplit, quote
from urllib.request import HTTPRedirectHandler, Request, build_opener

LANGUAGES = ('en', 'zh-CN', 'zh-TW', 'ja', 'fr', 'es', 'ko')
ORIGIN = 'https://www.subtitlecat.com'
SUBTITLECAT = 'Subtitle Cat'
PROVIDER_AUDIT = 'provider-search-audit.json'


class SubtitleRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not provider_url(newurl):
            raise ValueError('unreviewed_subtitle_redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def provider_url(url):
    parts = urlsplit(url)
    return (parts.scheme == 'https' and parts.hostname == 'www.subtitlecat.com'
            and parts.username is None and parts.port in (None, 443))


def read(url):
    if not provider_url(url):
        raise ValueError('unreviewed_subtitle_host')
    url = quote(url, safe=':/?&=%[]')
    with build_opener(SubtitleRedirect()).open(
            Request(url, headers={'User-Agent': 'BobTV-Subtitle/1.0'}), timeout=15) as response:
        if not provider_url(response.geturl()):
            raise ValueError('unreviewed_subtitle_redirect')
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('subtitle_response_limit')
    return raw


def page_links(node):
    return [dict(url=link.attrib.get('href', ''), id=link.attrib.get('id', ''),
                 text=link.get_all_text()) for link in node.css('a')]


def norm(text):
    return re.findall(r"[a-z]+(?:'[a-z]+)?|[0-9]+", html.unescape(text).lower())


def title_norm(text):
    # Release labels commonly omit possessive punctuation. Keep every title
    # word and the exact year while treating Clancy's / Clancys equally.
    return norm(html.unescape(text).replace("'", '').replace('\u2019', ''))


def matches_movie_title(label, title, year):
    """Match the complete title before its release year, never a prefix film."""
    expected = title_norm(title)
    words = title_norm(label)
    return bool(expected and words[:len(expected)] == expected
                and words[len(expected):len(expected)+1] == [str(year)])


def seconds(value):
    h, m, s = value.replace(',', '.').split(':')
    return int(h) * 3600 + int(m) * 60 + float(s)


def parse_srt(raw):
    text = raw.decode('utf-8-sig').replace('\r\n', '\n')
    cues = []
    for block in re.split(r'\n\s*\n', text.strip()):
        match = re.search(r'(\d{1,2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{3})[^\n]*\n(.*)', block, re.S)
        if not match:
            continue
        start, end = seconds(match[1]), seconds(match[2])
        caption = html.unescape(re.sub(r'<[^>]+>', '', match[3])).strip()
        if not (0 <= start < end <= 12 * 3600 and caption and len(caption) <= 8192):
            raise ValueError('invalid_subtitle_cue')
        cues.append(dict(index=len(cues) + 1, start=start, end=end, text=caption))
    if not 3 <= len(cues) <= 20000:
        raise ValueError('invalid_subtitle_count')
    return cues


def resource_path(root, url, language):
    key=hashlib.sha256(json.dumps([url,language],separators=(',',':')).encode()).hexdigest()
    return Path(root)/('subtitle-resource-'+key+'.json')


def save_resource(root, url, language, label, raw, provider, **facts):
    cues=parse_srt(raw);digest=hashlib.sha256(raw).hexdigest();root=Path(root)
    (root/(digest+'.srt')).write_bytes(raw)
    record=dict(provider=provider,url=url,language=language,label=label,
                sha256=digest,bytes=len(raw),cueCount=len(cues),**facts)
    resource_path(root,url,language).write_text(json.dumps(record,ensure_ascii=False))
    return record


def load_resource(root, url, language):
    try:
        record=json.loads(resource_path(root,url,language).read_text())
        digest=record['sha256']
        if record['url']!=url or record['language']!=language or not re.fullmatch(r'[0-9a-f]{64}',digest):return None
        raw=(Path(root)/(digest+'.srt')).read_bytes()
        if len(raw)!=record['bytes'] or len(raw)>2*1024*1024 or hashlib.sha256(raw).hexdigest()!=digest:return None
        return record,parse_srt(raw)
    except (OSError,ValueError,KeyError,UnicodeError):return None


def _discover_subtitlecat(title, year, root, *, max_candidates=3, requested_language='en'):
    """Title/year selects candidates only. An acoustic lock is mandatory later."""
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    search = ORIGIN + '/index.php?' + urlencode({'search': f'{title} {year}'})
    search_page = Selector(read(search))
    english_originals = set()
    failures = []
    for row in search_page.css('tr'):
        if '(translated from English)' in row.get_all_text():
            english_originals.update(link['url'] for link in page_links(row))
    matched_pages = {}
    offered_pages = set()
    for link in page_links(search_page):
        page = urljoin(ORIGIN, link['url'])
        if not (provider_url(page) and urlsplit(page).path.startswith('/subs/') and link['url'].endswith('.html')):
            continue
        offered_pages.add(page)
        if matches_movie_title(link['text'], title, year):
            matched_pages.setdefault(page, link)
    pages = []
    with download_pool() as pool:
        futures = [(page, candidate, pool.submit(read, page)) for page, candidate in matched_pages.items()]
        for page, candidate, future in futures:
            try:
                detail = Selector(future.result())
            except (OSError, ValueError, UnicodeError) as error:
                failures.append(_failure(error, url=page))
                continue
            links = dict.fromkeys(
                (link['id'].removeprefix('download_'), urljoin(ORIGIN, link['url']))
                for link in page_links(detail) if link['id'].startswith('download_')
                and provider_url(urljoin(ORIGIN, link['url']))
                and link['text'].strip() == 'Download' and link['url'].endswith('.srt')
                and link['id'].removeprefix('download_') in LANGUAGES)
            offered = {language for language, _ in links}
            priority = (requested_language not in offered,
                        not ('en' in offered or candidate['url'] in english_originals), -len(offered))
            pages.append((priority, page, candidate, detail, links))

    resources = {}
    results = []
    unidentified_language_rows = 0
    for _, page, candidate, detail, links in sorted(pages, key=lambda x: x[0]):
        subtitles = []
        for language, url in links:
            key = (language, url)
            if key not in resources:
                try:
                    cached = load_resource(root, url, language)
                    if cached:
                        record, cues = cached
                    else:
                        raw = read(url)
                        record = save_resource(root, url, language, candidate['text'], raw, SUBTITLECAT)
                        cues = parse_srt(raw)
                    actual = chinese_script(cues, language)
                    unidentified_language_rows += actual is None
                    facts = dict(record, declaredLanguage=language,
                        quality='existing provider file; translation quality unreviewed')
                    resources[key] = (actual, cues, facts, cached is not None)
                except (ValueError, OSError, UnicodeError) as error:
                    failures.append(_failure(error, url=url, language=language))
                    resources[key] = None
            source = resources[key]
            if source and source[0]:
                subtitles.append(source[:3])

        english = [(cues, facts) for language, cues, facts in subtitles if language == 'en']
        translations = [(lang, cues, facts) for lang, cues, facts in subtitles if lang != 'en']
        if not english and translations and candidate['url'] in english_originals:
            # The existing English text is tied to this page. Rebuild its times
            # only when the translation files with the same cue count agree on the grid.
            original = [item.get_all_text().strip() for item in detail.xpath(
                '//h3[normalize-space(.)="Original subtitles"]/following-sibling::p[@dir="auto"]')]
            grids = {tuple((cue['start'], cue['end']) for cue in cues): (lang, cues, facts)
                     for lang, cues, facts in translations if len(cues) == len(original)}
            if len(grids) == 1 and all(0 < len(text) <= 8192 for text in original):
                lang, cues, facts = next(iter(grids.values()))
                english.append(([{**cue, 'text': text} for cue, text in zip(cues, original)],
                    dict(url=page, cueCount=len(original), provider=SUBTITLECAT,
                         source='published English original with exact same-source cue grid',
                         clockGridLanguage=lang, clockGridSha256=facts['sha256'],
                         sha256=hashlib.sha256(json.dumps(original).encode()).hexdigest())))
        for cues, facts in english:
            # The detail page stays the reference for the HTML original. A real
            # English file has its own URL and can carry a different timeline.
            results.extend(pair_reference(dict(page=facts['url'], label=candidate['text'], searchUrl=search),
                                         cues, facts, translations))

    parsed = [value for value in resources.values() if value is not None]
    (root/'subtitlecat-search-audit.json').write_text(json.dumps(dict(
        htmlParser='scrapling', offeredRows=len(offered_pages), matchedEditions=len(matched_pages), detailsRead=len(pages),
        selectedRows=len(resources), parsedRows=len(parsed),
        downloadedRows=sum(not result[3] for result in parsed),
        cacheHits=sum(result[3] for result in parsed), unidentifiedLanguageRows=unidentified_language_rows,
        downloadedLanguages=sorted({value[0] for value in parsed if value[0]}),
        allMatchingRowsAttempted=True, failures=failures)))
    return results


def _failure(error, **context):
    return {**context, 'errorType': type(error).__name__, 'httpStatus': getattr(error, 'code', None)}


def variant_counts(candidates):
    transcripts = {language: set() for language in LANGUAGES}
    for candidate in candidates:
        for language, cues in candidate['tracks'].items():
            if language in transcripts and cues:
                transcripts[language].add(transcript_fingerprint(cues))
    return {language: len(values) for language, values in transcripts.items() if values}


def _provider_outcome(rows, audit, failures):
    if failures:
        return 'partial' if rows or audit.get('parsedRows') else 'unavailable'
    if rows:
        return 'found'
    if audit.get('parsedRows'):
        return 'timing_pending'
    if audit.get('reason') in ('ambiguous_imdb_result', 'title_year_or_type_mismatch', 'unsupported_provider_detail_url'):
        return 'identity_pending'
    return 'no_matching_release'


def discover(title, year, root, *, max_candidates=3, requested_language='en', imdb_id=None,
             aliases=(), reviewer=None):
    """Search every applicable source and retain all proven acoustic editions."""
    from subtitle_stremio import discover as stremio_discover, PROVIDER as STREMIO
    from subtitle_subdl import discover as subdl_discover, PROVIDER as SUBDL

    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    imdb_verified = isinstance(imdb_id, str) and bool(re.fullmatch(r'tt[0-9]{7,10}', imdb_id))
    adapters = (
        (STREMIO, 'opensubtitles-search-audit.json', stremio_discover, True),
        (SUBTITLECAT, 'subtitlecat-search-audit.json', _discover_subtitlecat, False),
        (SUBDL, 'subdl-discovery.json', subdl_discover, True),
    )
    results, errors, reports = [], [], []
    last_error = None
    for provider, filename, adapter, needs_imdb in adapters:
        audit_file = root/filename
        audit_file.unlink(missing_ok=True)
        report = dict(provider=provider, acceptedEditions=0, acceptedVariantCounts={})
        if needs_imdb and not imdb_verified:
            reports.append(dict(report, outcome='skipped', reason='verified_imdb_required'))
            continue
        options = {'imdb_id': imdb_id} if needs_imdb else {'requested_language': requested_language}
        if needs_imdb and aliases:
            options['aliases'] = aliases
        try:
            rows = adapter(title, year, root, max_candidates=max_candidates, **options)
            audit = json.loads(audit_file.read_text()) if audit_file.exists() else {}
            # The provider-specific file can include full cue lists. The ledger
            # records only counts and reasons, so it stays small in the cache.
            counters = {key: audit[key] for key in (
                'offeredRows', 'selectedRows', 'parsedRows', 'downloadedRows', 'cacheHits',
                'matchedEditions', 'detailsRead', 'identityRows', 'unidentifiedLanguageRows',
                'downloadedLanguages', 'allMatchingRowsAttempted', 'htmlParser', 'reason') if key in audit}
            failures = audit.get('failures', [])
            reports.append(dict(report, **counters, acceptedEditions=len(rows),
                acceptedVariantCounts=variant_counts(rows), outcome=_provider_outcome(rows, audit, failures),
                failureCount=len(failures)))
            errors.extend(dict(provider=provider, **failure) for failure in failures)
            results.extend(rows)
        except Exception as error:
            failure = _failure(error)
            reports.append(dict(report, **failure, outcome='unavailable', failureCount=1))
            errors.append(dict(provider=provider, **failure))
            last_error = error
    if not results and reviewer is not None and imdb_verified:
        try:
            reviewed = stremio_discover(title, year, root, max_candidates=max_candidates,
                imdb_id=imdb_id, aliases=aliases, reviewer=reviewer)
            results.extend(reviewed)
            reports.append(dict(provider=STREMIO, stage='ai_identity_review',
                outcome='found' if reviewed else 'no_matching_release',
                acceptedEditions=len(reviewed)))
        except (OSError, ValueError, TypeError, KeyError) as error:
            errors.append(dict(provider=STREMIO, **_failure(error)))
    (root/PROVIDER_AUDIT).write_text(json.dumps(dict(requestedLanguage=requested_language,
        providerOutcomes=reports, acceptedVariantCounts=variant_counts(results)), ensure_ascii=False))
    print(json.dumps(dict(event='subtitle_search', language=requested_language,
        providers={item['provider']: item['outcome'] for item in reports},
        variants=variant_counts(results))), flush=True)
    (root/'provider-errors.json').write_text(json.dumps(errors))
    (root/'discovery.json').write_text(json.dumps(results, ensure_ascii=False))
    if not results and errors:
        raise last_error or RuntimeError('subtitle_provider_incomplete')
    return results
