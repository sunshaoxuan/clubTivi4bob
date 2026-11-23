"""Persistent, movie/edition/language subtitle resources; never cache live offsets."""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import time
import unicodedata
from urllib.parse import urlsplit

from subtitle_edition import chinese_script, merge_editions, timing_evidence, track_fingerprint
from subtitle_identity import resolve as resolve_identity, release_year
from subtitle_ai import SubtitleAI, TARGETS, PROVIDER as AI_PROVIDER
from subtitle_catalog import (LANGUAGES, PROVIDER_AUDIT, matches_movie_title, parse_srt,
                              resource_path, title_norm, variant_counts)

NEGATIVE_TTL = 900
RETRY_TTL = 60
RESOURCE_SCHEMA = 5


def verified_release_aliases(programme):
    if programme.get('identityEvidence')=='reviewed_localized_title_pending_audio_verification':
        aliases=programme.get('verifiedTitleAliases',[])
        if (not re.fullmatch(r'tt[0-9]{7,10}',str(programme.get('imdbId','')))
                or not isinstance(aliases,list) or len(aliases)>6
                or any(not isinstance(name,str) or not 1<=len(name)<=200 for name in aliases)):
            return ()
        return tuple(aliases)
    if programme.get('identityEvidence')!='official_movie_record' or not programme.get('imdbId'):
        return ()
    slug = programme.get('movieId') or ''
    if '-aka-' not in slug:
        return ()
    alias = slug.rsplit('-aka-',1)[-1].replace('-',' ')
    return (alias,) if re.fullmatch(r'[a-z0-9 ]{2,80}',alias) else ()


def movie_aliases(programme):
    aliases = []
    imdb = programme.get('imdbId')
    if imdb is not None:
        if not (isinstance(imdb, str) and re.fullmatch(r'tt[0-9]{7,10}', imdb)):
            raise ValueError('unverified_imdb_identifier')
        aliases.append('imdb:' + imdb)
    movie = programme.get('movieId')
    if movie:
        if not isinstance(movie,str) or not re.fullmatch(r'[a-z0-9-]{1,200}', movie):
            raise ValueError('invalid_official_movie_identifier')
        aliases.append('rakuten:' + programme.get('marketCode', 'uk') + ':' + movie)
    title, year = programme.get('title'), programme.get('year')
    if not isinstance(title, str) or not title.strip() or not isinstance(year, int) or not 1888 <= year <= 2100:
        raise ValueError('movie_title_and_year_required')
    if not aliases:
        # Title alone cannot distinguish remakes or unrelated films.
        aliases.append('title-year:' + json.dumps([re.findall(r'[^\W_]+', unicodedata.normalize('NFKC', title).casefold()), year], separators=(',', ':')))
    return aliases


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def srt_bytes(cues):
    def stamp(seconds):
        ms = round(seconds * 1000)
        return f'{ms//3600000:02}:{ms//60000%60:02}:{ms//1000%60:02},{ms%1000:03}'
    return '\n\n'.join(f"{i}\n{stamp(c['start'])} --> {stamp(c['end'])}\n{c['text']}" for i, c in enumerate(cues, 1)).encode()


class SubtitleCache:
    def __init__(self, root, *, clock=time.time, legacy_roots=()):
        self.legacy_roots = tuple(Path(p) for p in legacy_roots)
        self.root, self.clock = Path(root), clock
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.root/'blobs').mkdir(exist_ok=True, mode=0o700)
        self.ai = SubtitleAI(self.root/'.ai')

    def with_ai_translation(self, programme, candidates, language, *, reference_page=None,
                            cancelled=lambda:False):
        if (language not in TARGETS or not candidates or not self.ai.enabled or
                not programme.get('searchable') or not programme.get('imdbId') or
                not programme.get('identityEvidence')):
            return candidates
        reference=next((row for row in candidates
            if (row.get('provenance',{}).get('en',{}).get('imdbId')==programme['imdbId']
                or reference_page is not None and row['page']==reference_page
                and row.get('provenance',{}).get('en',{}).get('imdbId') is None
                and row.get('provenance',{}).get('en',{}).get('provider')=='Subtitle Cat')
            and row['tracks'].get('en') and not row.get('provenance',{}).get('en',{}).get('generated')
            and (reference_page is None or row['page']==reference_page)),None)
        if (reference is None or reference['tracks'].get(language) or
                not self.ai.permits_translation(reference.get('provenance',{}).get('en',{}))):
            return candidates
        english=reference['tracks']['en']
        cues=self.ai.translate(programme['title'],english,language,cancelled=cancelled)
        if not cues:return candidates
        translated={**reference,'tracks':{**reference['tracks'],language:cues},
            'provenance':{**reference.get('provenance',{}),language:{
                'provider':AI_PROVIDER,'release':f'AI {language} · proofread','generated':True,
                'referenceFingerprint':track_fingerprint(english),'pipeline':2}}}
        return [translated if item is reference else item for item in candidates]

    # Compatibility for external diagnostic callers; new production scheduling
    # uses the exact requested language, including Traditional Chinese.
    def with_ai_chinese(self, programme, candidates, language, **options):
        return self.with_ai_translation(programme,candidates,language,**options)

    def identity(self, programme):
        aliases = movie_aliases(programme)
        with sqlite3.connect(self.root/'identities.sqlite3', timeout=15) as db:
            db.execute('CREATE TABLE IF NOT EXISTS aliases(alias TEXT PRIMARY KEY, cache_key TEXT NOT NULL)')
            db.execute('BEGIN IMMEDIATE')
            keys = {r[0] for a in aliases for r in db.execute('SELECT cache_key FROM aliases WHERE alias=?', (a,))}
            if len(keys) > 1: raise ValueError('conflicting_movie_identity_requires_review')
            key = next(iter(keys)) if keys else aliases[0]
            for alias in aliases:
                db.execute('INSERT OR IGNORE INTO aliases VALUES (?,?)', (alias, key))
        return hashlib.sha256(key.encode()).hexdigest()

    @contextlib.contextmanager
    def locked(self, key):
        folder = self.root/key; folder.mkdir(exist_ok=True, mode=0o700)
        with (folder/'lookup.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try: yield folder
            finally: fcntl.flock(lock, fcntl.LOCK_UN)

    def load(self, folder):
        try:
            manifest = json.loads((folder/'index.json').read_text())
            if manifest['schemaVersion'] != 1: raise ValueError('cache_schema')
        except (OSError, ValueError, KeyError): return [], {}
        candidates = []
        for edition in manifest.get('editions', []):
            tracks, provenance = {}, {}
            for language, record in edition['tracks'].items():
                if language not in LANGUAGES or not re.fullmatch(r'[0-9a-f]{64}', record['sha256']): continue
                try:
                    raw = (self.root/'blobs'/(record['sha256']+'.srt')).read_bytes()
                    if len(raw) != record['bytes'] or hashlib.sha256(raw).hexdigest() != record['sha256']: continue
                    tracks[language] = parse_srt(raw)
                    provenance[language] = record['provenance']
                except (OSError, ValueError, UnicodeError): continue
            if 'en' not in tracks: continue
            tracks = {lang: cues for lang, cues in tracks.items() if timing_evidence(tracks['en'],cues,provenance.get('en'),provenance.get(lang))}
            candidates.append({**edition['metadata'], 'tracks': tracks,
                               'provenance': {lang:provenance[lang] for lang in tracks}, 'cacheHit': True})
        return candidates, manifest.get('searches', {})

    def resource_records(self, folder):
        try:return json.loads((folder/'index.json').read_text()).get('resources',[])
        except (OSError,ValueError):return []

    def resource_bytes(self, record, root):
        try:
            url=urlsplit(record['url']);language=record['language'];sha=record['sha256']
            if (language not in (*LANGUAGES, 'zh') or url.scheme!='https' or url.username
                    or url.port not in (None,443) or url.hostname not in ('www.subtitlecat.com','dl.subdl.com','subs5.strem.io')
                    or not re.fullmatch(r'[0-9a-f]{64}',sha)):
                return None
            raw=(Path(root)/(sha+'.srt')).read_bytes()
            if not 0<len(raw)<=2*1024*1024 or len(raw)!=record['bytes'] or hashlib.sha256(raw).hexdigest()!=sha:return None
            parse_srt(raw)
            return raw
        except (OSError,ValueError,KeyError,UnicodeError,TypeError):return None

    def hydrate_resources(self, folder, download_root):
        for record in self.resource_records(folder):
            raw=self.resource_bytes(record,self.root/'blobs')
            if raw is None:continue
            destination=Path(download_root);destination.mkdir(parents=True,exist_ok=True)
            atomic(destination/(record['sha256']+'.srt'),raw)
            atomic(resource_path(destination,record['url'],record['language']),json.dumps(record,ensure_ascii=False).encode())

    def preserve_resources(self, folder, download_root):
        records={(r['url'],r['language']):r for r in self.resource_records(folder)
                 if self.resource_bytes(r,self.root/'blobs') is not None}
        for path in Path(download_root).glob('subtitle-resource-*.json'):
            try:source=json.loads(path.read_text())
            except (OSError,ValueError):continue
            raw=self.resource_bytes(source,download_root)
            if raw is None:continue
            record = {key: source[key] for key in (
                'provider', 'url', 'language', 'label', 'sha256', 'bytes', 'cueCount',
                'archiveSha256', 'imdbId', 'identityLookup') if key in source}
            record['actualLanguage'] = chinese_script(parse_srt(raw), source['language'])
            atomic(self.root/'blobs'/(record['sha256']+'.srt'),raw)
            records[(record['url'],record['language'])]=record
        return list(records.values())

    @staticmethod
    def provider_outcomes(download_root):
        try:
            audit = json.loads((Path(download_root)/PROVIDER_AUDIT).read_text())
            return audit.get('providerOutcomes', [])
        except (OSError, ValueError):
            return []

    def store(self, folder, programme, candidates, download_root, *, searched=False):
        editions = []
        admitted = []
        for candidate in candidates:
            if 'en' not in candidate['tracks']: continue
            records = {}
            verified_tracks = {}
            for language, cues in candidate['tracks'].items():
                facts = candidate.get('provenance', {}).get(language, {})
                evidence=timing_evidence(candidate['tracks']['en'],cues,candidate.get('provenance',{}).get('en'),facts)
                if language not in LANGUAGES or not evidence: continue
                facts={**facts,'timingEvidence':evidence}
                raw = srt_bytes(cues)
                original = facts.get('sha256', '')
                if re.fullmatch(r'[0-9a-f]{64}', original):
                    file = Path(download_root)/(original+'.srt')
                    if file.exists():
                        downloaded = file.read_bytes()
                        if hashlib.sha256(downloaded).hexdigest() == original and parse_srt(downloaded) == cues:
                            raw = downloaded
                parse_srt(raw)
                digest = hashlib.sha256(raw).hexdigest()
                atomic(self.root/'blobs'/(digest+'.srt'), raw)
                records[language] = dict(sha256=digest, bytes=len(raw), provenance=facts)
                verified_tracks[language] = cues
            metadata = {k:candidate[k] for k in ('page','label','searchUrl','rejectedClockGridLanguages') if k in candidate}
            signature = {language: track_fingerprint(cues) for language, cues in verified_tracks.items()}
            edition = hashlib.sha256(json.dumps([candidate['page'], signature], sort_keys=True).encode()).hexdigest()
            editions.append(dict(id=edition, metadata=metadata, tracks=records))
            admitted.append({'tracks': verified_tracks})
        resources=self.preserve_resources(folder,download_root)
        paired={record['sha256'] for e in editions for record in e['tracks'].values()}
        for resource in resources:resource['pairedWithEnglish']=resource['sha256'] in paired
        available = variant_counts(admitted)
        outcomes = self.provider_outcomes(download_root)
        errors_path=Path(download_root)/'provider-errors.json'
        try:provider_errors=json.loads(errors_path.read_text())
        except (OSError,ValueError):provider_errors=[]
        pending = {resource.get('actualLanguage', resource['language'])
                   for resource in resources if not resource['pairedWithEnglish']}
        if None in pending or 'zh' in pending:
            pending.update(('zh-CN', 'zh-TW'))
        identity_pending = any(row.get('outcome') == 'identity_pending'
                               or row.get('reason') == 'verified_imdb_required'
                               for row in outcomes)
        searches = {}
        for language in LANGUAGES:
            variants = available.get(language, 0)
            if provider_errors:
                outcome = 'temporarily_unavailable'
            elif variants:
                outcome = 'cached'
            elif language in pending:
                outcome = 'timing_pending'
            elif identity_pending:
                outcome = 'identity_pending'
            else:
                outcome = 'not_found_this_search'
            searches[language] = dict(checkedAt=self.clock(), outcome=outcome, variantCount=variants)
        atomic(folder/'index.json', json.dumps(dict(schemaVersion=1,
            lookupAliases=list(verified_release_aliases(programme)),
            resourceSchemaVersion=RESOURCE_SCHEMA if searched else 3, identity=movie_aliases(programme),
            title=programme['title'], year=programme['year'], subtitleYear=programme.get('subtitleYear',programme['year']),
            editions=editions, resources=resources, searches=searches, providerOutcomes=outcomes),
            ensure_ascii=False).encode())

    def import_existing(self, programme, folder):
        for root in self.legacy_roots:
            for path in root.glob('**/subtitles/discovery.json'):
                try:
                    if path.stat().st_size > 32*1024*1024: continue
                    decisions = path.parent.parent/'decisions.jsonl'
                    with decisions.open('rb') as stream:
                        stream.seek(max(0, decisions.stat().st_size-65536))
                        lines = stream.read().splitlines()
                    observed = None
                    for line in reversed(lines[-10:]):
                        try: observed=json.loads(line);break
                        except ValueError: continue
                    if not observed or observed.get('program') != programme.get('movieId'): continue
                    candidates = json.loads(path.read_text())
                    candidates = [c for c in candidates if matches_movie_title(c.get('label',''), programme['title'], programme['year'])]
                    if not candidates: continue
                    self.store(folder, programme, candidates, path.parent)
                    return True
                except (OSError, ValueError, KeyError, TypeError): continue
        return False

    def get_or_discover(self, programme, download_root, discover, *, requested_language='en', refresh=False):
        if requested_language not in LANGUAGES: raise ValueError('unsupported_language')
        programme=resolve_identity(programme,self.root)
        release_aliases = verified_release_aliases(programme)
        with self.locked(self.identity(programme)) as folder:
            cached, searches = self.load(folder)
            try:
                manifest=json.loads((folder/'index.json').read_text())
                resource_schema=manifest.get('resourceSchemaVersion',0)
                if programme.get('imdbId') and 'imdb:'+programme['imdbId'] not in manifest.get('identity',[]):resource_schema=0
            except (OSError,ValueError):resource_schema=0;manifest={}
            if manifest.get('lookupAliases',[])!=list(release_aliases):searches={}
            if resource_schema < RESOURCE_SCHEMA:
                searches = {key: result for key, result in searches.items()
                            if result.get('outcome') == 'temporarily_unavailable'}
            if not cached and not searches and self.import_existing(programme, folder):
                cached, searches = self.load(folder)
                # An observed legacy edition is immediately usable once. The
                # next request upgrades its old, non-exhaustive search record.
                if not refresh and any(requested_language in row['tracks'] for row in cached):
                    return cached
            lookup_year=programme['year']
            if not cached or manifest.get('subtitleYear',programme['year'])!=programme['year']:
                verified_year=release_year(programme,self.root)
                if verified_year is not None:lookup_year=verified_year
                if lookup_year!=manifest.get('subtitleYear',programme['year']):searches={}
            programme={**programme,'subtitleYear':lookup_year}
            def same_film(candidate):
                label = candidate.get('label', '')
                facts = candidate.get('provenance', {}).get('en', {})
                source_imdb = facts.get('imdbId')
                if source_imdb is not None and programme.get('imdbId') not in (None, source_imdb):
                    return False
                return (any(matches_movie_title(label, name, lookup_year) for name in
                            (programme['title'],*release_aliases)) or
                        bool(source_imdb and source_imdb == programme.get('imdbId') and
                             (facts.get('aiIdentityReviewed') is True or any(
                                 title_norm(label)==title_norm(name) for name in release_aliases))) or
                        bool(source_imdb and source_imdb == programme.get('imdbId')
                             and title_norm(label) == title_norm(programme['title'])))
            admitted = [candidate for candidate in cached if same_film(candidate)]
            if len(admitted) != len(cached):
                # Old prefix matches must neither poison this IMDb identity nor
                # retain their negative language-search TTL after rejection.
                cached, searches = admitted, {}
            languages = {lang for candidate in cached for lang in candidate['tracks']}
            attempted = searches.get(requested_language, {})
            age = self.clock()-attempted.get('checkedAt', 0)
            outcome = attempted.get('outcome')
            fresh_miss = outcome in ('not_found_this_search', 'timing_pending', 'identity_pending') and age < NEGATIVE_TTL
            recent_error = outcome == 'temporarily_unavailable' and age < RETRY_TTL
            if recent_error:
                if cached: return cached
                raise RuntimeError('subtitle_provider_temporarily_unavailable')
            if refresh and resource_schema >= RESOURCE_SCHEMA and outcome and age < RETRY_TTL:
                return cached
            if not refresh and cached and resource_schema >= RESOURCE_SCHEMA and (
                    (requested_language in languages and outcome != 'temporarily_unavailable') or fresh_miss):
                return cached
            if not refresh and not cached and fresh_miss: return []
            self.hydrate_resources(folder,download_root)
            try:
                options = dict(requested_language=requested_language,imdb_id=programme.get('imdbId'))
                if release_aliases: options['aliases'] = release_aliases
                if self.ai.enabled and programme.get('searchable') and programme.get('identityEvidence'):
                    options['reviewer'] = self.ai.review
                found = discover(programme['title'],lookup_year,download_root,**options)
            except Exception:
                try: manifest = json.loads((folder/'index.json').read_text())
                except (OSError, ValueError): manifest = dict(schemaVersion=1, identity=movie_aliases(programme), title=programme['title'], year=programme['year'], editions=[], searches={})
                manifest['resources']=self.preserve_resources(folder,download_root)
                for resource in manifest['resources']:resource.setdefault('pairedWithEnglish',False)
                manifest.setdefault('searches', {})[requested_language] = dict(checkedAt=self.clock(), outcome='temporarily_unavailable')
                outcomes = self.provider_outcomes(download_root)
                if outcomes:
                    manifest['providerOutcomes'] = outcomes
                atomic(folder/'index.json', json.dumps(manifest, ensure_ascii=False).encode())
                if cached: return cached
                raise
            # Retain previously valid languages/editions if a later provider
            # search temporarily omits them. Different English grids stay separate.
            values = sorted(merge_editions([*cached, *found]),
                key=lambda c: 0 if c.get('provenance',{}).get('en',{}).get('provider')=='OpenSubtitles via Stremio' else 1)
            self.store(folder, programme, values, download_root, searched=True)
            return values
