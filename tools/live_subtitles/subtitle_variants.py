"""Stable, deduplicated subtitle choices offered for the current programme."""
from collections import defaultdict
import hashlib

from subtitle_catalog import LANGUAGES
from subtitle_edition import track_fingerprint, transcript_fingerprint

UNCHANGED = object()


class SubtitleVariants:
    def __init__(self, candidates):
        self.candidates = candidates
        self._tracks = {}
        self._stale = {}
        self._ref_keys = {}
        self._choices = defaultdict(list)
        self._by_id = defaultdict(list)
        for candidate in candidates or ():
            tracks = self._build_tracks(candidate)
            for language, choice in tracks.items():
                self._by_id[choice['id']].append(candidate)
                self._choices[language].append(choice)
                self._ref_keys[id(candidate), language] = track_fingerprint(candidate['tracks'][language])
            self._tracks[id(candidate)] = tracks

    @staticmethod
    def _build_tracks(candidate):
        facts = candidate.get('provenance', {})
        tracks = {}
        for language, cues in candidate['tracks'].items():
            if language not in LANGUAGES or not cues:
                continue
            digest = transcript_fingerprint(cues)
            provenance = facts.get(language, {})
            if provenance.get('generated') and provenance.get('referenceFingerprint'):
                digest=f"ai:{provenance.get('pipeline',2)}:{provenance['referenceFingerprint']}"
            variant_id = hashlib.sha256(f'{language}:{digest}'.encode()).hexdigest()
            tracks[language] = dict(id=variant_id, language=language,
                provider=str(provenance.get('provider') or '')[:80],
                label=str(provenance.get('release') or candidate.get('label') or '')[:200],
                generated=provenance.get('generated') is True)
        return tracks

    def _candidate_tracks(self, candidate):
        if candidate is None:
            return {}
        tracks = self._tracks.get(id(candidate))
        if tracks is not None:
            return tracks
        # A renamed or refreshed cache can leave one viewer on a known edition.
        # Preserve that proven track until a compatible replacement is available.
        key = id(candidate)
        if key not in self._stale:
            if len(self._stale) >= 32:
                self._stale.clear()
            self._stale[key] = (candidate, self._build_tracks(candidate))
        return self._stale[key][1]

    def track(self, candidate, language):
        return self._candidate_tracks(candidate).get(language)

    def key(self, candidate, language):
        if candidate is None:
            return None
        key = self._ref_keys.get((id(candidate), language))
        if key is None and (cues := candidate['tracks'].get(language)):
            key = track_fingerprint(cues)
        return key

    def supports(self, candidate, variant_id):
        return any(track['id'] == variant_id for track in self._candidate_tracks(candidate).values())

    def matching(self, variant_id):
        return self._by_id.get(variant_id, ())

    def choices(self, reference, pinned=None):
        result = []
        for language in LANGUAGES:
            options = self._choices[language]
            unique = {}
            active = self.track(reference, language)
            choice = next((option for option in options if option['id'] == pinned), None) if pinned else None
            def add(option):
                if option is None:return
                if option['generated'] and any(row['generated'] for row in unique.values()):return
                unique.setdefault(option['id'],option)
            # A pinned AI edition remains addressable during clock acquisition.
            if choice and choice['generated']:add(choice)
            add(active)
            add(choice)
            used_providers = {choice['provider'] for choice in unique.values()}
            for option in options:
                if len(unique) >= 3:
                    break
                if option['provider'] not in used_providers and option['id'] not in unique:
                    add(option)
                    used_providers.add(option['provider'])
            for option in options:
                if len(unique) >= 3:
                    break
                add(option)
            result.extend(unique.values())
        return result
