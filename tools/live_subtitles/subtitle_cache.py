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

from subtitle_catalog import LANGUAGES, parse_srt, title_norm

NEGATIVE_TTL = 900


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
            grid = [(c['start'], c['end']) for c in tracks['en']]
            tracks = {lang: cues for lang, cues in tracks.items() if [(c['start'], c['end']) for c in cues] == grid}
            candidates.append({**edition['metadata'], 'tracks': tracks,
                               'provenance': {lang:provenance[lang] for lang in tracks}, 'cacheHit': True})
        return candidates, manifest.get('searches', {})

    def store(self, folder, programme, candidates, download_root):
        editions = []
        for candidate in candidates:
            if 'en' not in candidate['tracks']: continue
            grid = [(c['start'], c['end']) for c in candidate['tracks']['en']]
            records = {}
            for language, cues in candidate['tracks'].items():
                if language not in LANGUAGES or [(c['start'], c['end']) for c in cues] != grid: continue
                facts = candidate.get('provenance', {}).get(language, {})
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
            metadata = {k:candidate[k] for k in ('page','label','searchUrl','rejectedClockGridLanguages') if k in candidate}
            edition = hashlib.sha256(json.dumps([candidate['page'], records['en']['sha256']], sort_keys=True).encode()).hexdigest()
            editions.append(dict(id=edition, metadata=metadata, tracks=records))
        available = {lang for e in editions for lang in e['tracks']}
        searches = {lang:dict(checkedAt=self.clock(), outcome='cached' if lang in available else 'not_found_this_search') for lang in LANGUAGES}
        atomic(folder/'index.json', json.dumps(dict(schemaVersion=1, identity=movie_aliases(programme),
            title=programme['title'], year=programme['year'], editions=editions, searches=searches), ensure_ascii=False).encode())

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
                    required = set(title_norm(programme['title'])) | {str(programme['year'])}
                    candidates = [c for c in candidates if required <= set(title_norm(c.get('label','')))]
                    if not candidates: continue
                    self.store(folder, programme, candidates, path.parent)
                    return True
                except (OSError, ValueError, KeyError, TypeError): continue
        return False

    def get_or_discover(self, programme, download_root, discover, *, requested_language='en'):
        if requested_language not in LANGUAGES: raise ValueError('unsupported_language')
        with self.locked(self.identity(programme)) as folder:
            cached, searches = self.load(folder)
            if not cached and not searches and self.import_existing(programme, folder):
                cached, searches = self.load(folder)
            languages = {lang for candidate in cached for lang in candidate['tracks']}
            attempted = searches.get(requested_language, {})
            age = self.clock()-attempted.get('checkedAt', 0)
            fresh_miss = attempted.get('outcome') == 'not_found_this_search' and age < NEGATIVE_TTL
            recent_error = attempted.get('outcome') == 'temporarily_unavailable' and age < 60
            if recent_error:
                if cached: return cached
                raise RuntimeError('subtitle_provider_temporarily_unavailable')
            if cached and (requested_language in languages or fresh_miss): return cached
            if not cached and fresh_miss: return []
            try:
                found = discover(programme['title'], programme['year'], download_root, requested_language=requested_language)
            except Exception:
                try: manifest = json.loads((folder/'index.json').read_text())
                except (OSError, ValueError): manifest = dict(schemaVersion=1, identity=movie_aliases(programme), title=programme['title'], year=programme['year'], editions=[], searches={})
                manifest.setdefault('searches', {})[requested_language] = dict(checkedAt=self.clock(), outcome='temporarily_unavailable')
                atomic(folder/'index.json', json.dumps(manifest, ensure_ascii=False).encode())
                if cached: return cached
                raise
            # Retain previously valid languages/editions if a later provider
            # search temporarily omits them. Different English grids stay separate.
            merged = {hashlib.sha256(json.dumps([c['page'],c['tracks']['en']],sort_keys=True).encode()).hexdigest():c for c in cached}
            for candidate in found:
                key = hashlib.sha256(json.dumps([candidate['page'],candidate['tracks']['en']],sort_keys=True).encode()).hexdigest()
                previous = merged.get(key)
                if previous:
                    candidate = {**candidate,'tracks':{**previous['tracks'],**candidate['tracks']},'provenance':{**previous.get('provenance',{}),**candidate.get('provenance',{})}}
                merged[key] = candidate
            values = list(merged.values())
            self.store(folder, programme, values, download_root)
            return values
