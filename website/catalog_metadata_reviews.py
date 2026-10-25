"""Explicit identity/route-bound geographic corrections, independent of category.

No partial names, stream-host guesses or category-derived jurisdiction rules.
An unexpected identity or additional unreviewed route leaves the entry untouched.
"""
import hashlib
import json
from pathlib import Path
import re
from source_registry import validate_public_url

REVIEWS = Path(__file__).with_name('catalog_metadata_reviews.json')
IDENTITY_FIELDS = ('id', 'name', 'epgId', 'countryCode', 'regionCode')


def apply_reviews(channels, path=REVIEWS):
    path = Path(path)
    if not path.is_file(): return []
    if path.stat().st_size > 64 * 1024: raise ValueError('catalog_metadata_review_limit')
    value = json.loads(path.read_text())
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'reviews'}
            or value['schemaVersion'] != 1 or not isinstance(value['reviews'], list)
            or len(value['reviews']) > 20): raise ValueError('invalid_catalog_metadata_reviews')
    seen, prepared = set(), []
    for review in value['reviews']:
        if not isinstance(review, dict) or set(review) != {'expectedIdentity', 'routeSha256',
                'countryCode', 'regionCode', 'reviewedAt', 'evidenceUrls'}:
            raise ValueError('invalid_catalog_metadata_review')
        expected = review['expectedIdentity']
        if (not isinstance(expected, dict) or set(expected) != set(IDENTITY_FIELDS)
                or not isinstance(expected['id'], str) or expected['id'] in seen
                or not re.fullmatch(r'[A-Z]{2}', review['countryCode'])
                or review['regionCode'] is not None and not re.fullmatch(r'[A-Z0-9-]{1,12}', review['regionCode'])
                or not isinstance(review['routeSha256'], list) or not 1 <= len(review['routeSha256']) <= 5
                or any(not re.fullmatch(r'[a-f0-9]{64}', item) for item in review['routeSha256'])
                or not isinstance(review['reviewedAt'], str) or not review['reviewedAt'].endswith('Z')
                or not isinstance(review['evidenceUrls'], list) or not 1 <= len(review['evidenceUrls']) <= 5):
            raise ValueError('invalid_catalog_metadata_review')
        for url in review['evidenceUrls']: validate_public_url(url)
        seen.add(expected['id']); prepared.append(review)
    by_id = {channel['id']: channel for channel in channels}
    applied = []
    for review in prepared:
        channel = by_id.get(review['expectedIdentity']['id'])
        if not channel or any(channel.get(key) != val for key, val in review['expectedIdentity'].items()):
            continue
        hashes = {hashlib.sha256(route['url'].encode()).hexdigest() for route in channel['routes']}
        if not hashes or not hashes <= set(review['routeSha256']): continue
        channel.update(countryCode=review['countryCode'], regionCode=review['regionCode'])
        applied.append(channel['id'])
    return applied
