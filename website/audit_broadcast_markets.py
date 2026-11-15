"""Offline, read-only full-catalog edition-market audit and review proposals.

Usage: python audit_broadcast_markets.py snapshot.json output.json
No network, SQL, publication, EPG remapping, user category or identity writes.
Indicators only open review findings. They cannot determine a new country.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import os
import tempfile
from urllib.parse import urlsplit

from broadcast_market import POLICY_VERSION, category_path, review_channel
from country_names import _DATA


def _country_aliases(names):
    by_label = {label: ('GB' if code.lower() == 'uk' else code.upper())
                for code, label in names.items()}
    return {**{label.casefold(): code for label, code in by_label.items()},
            **{a.casefold(): by_label.get(label) for a, label in _DATA['aliases'].items()}}


def edition_hints(channel, names, aliases=None):
    """Find explicit edition conflicts without promoting them to authority."""
    hints = []
    epg = channel.get('epgId') or ''
    # @Germany/@Poland can qualify a feed whose base id registers elsewhere.
    suffix = epg.partition('@')[2]
    aliases = _country_aliases(names) if aliases is None else aliases
    # SD is video quality here, never the ISO country code for Sudan.
    code = (aliases.get(suffix.casefold()) if suffix
            and suffix.casefold() not in {'sd', 'hd', 'fhd', 'uhd', '4k', '8k'} else None)
    if code:
        hints.append({'kind': 'explicit_epg_edition_suffix', 'marketHint': code})
    # A platform channel id prefix is only a lead until platform-bound evidence.
    samsung = re.fullmatch(r'([A-Z]{2})\d{5,}[A-Z0-9]{2}', epg)
    logo_host = (urlsplit(channel.get('logoUrl') or '').hostname or '').lower()
    if (samsung and samsung[1].lower() in names
            and logo_host.endswith('.samsungcloud.tv')):
        hints.append({'kind': 'platform_epg_id_prefix', 'marketHint': samsung[1]})
    for route in channel.get('routes', []):
        host = (urlsplit(route['url']).hostname or '').lower()
        match = re.fullmatch(r'.+-rakuten-tv-([a-z]{2})\.fast\.rakuten\.tv', host)
        if match:
            market = 'GB' if match[1] == 'uk' else match[1].upper()
            if market.lower() in names:
                hints.append({'kind': 'provider_host_edition_token', 'marketHint': market})
    return [dict(value) for value in {tuple(sorted(h.items())) for h in hints}]


def audit(payload, bindings, protected_ids=frozenset()):
    categories = {c['id']: c for c in payload['categories']}
    results, findings = [], []
    names = _DATA['names']
    aliases = _country_aliases(names)
    statuses = Counter()
    for channel in payload['channels']:
        result = review_channel(channel, categories, bindings, names,
                                protected=channel['id'] in protected_ids)
        statuses['unbound' if result.get('reason') == 'unbound_route' else result['status']] += 1
        if result['status'] in ('proposed_correction', 'protected_review'):
            results.append(result)
        path = category_path(channel, categories)
        current = channel.get('countryCode')
        risks = []
        expected = names.get((current or '').lower())
        if expected and path[:1] == ['国际'] and len(path) >= 2 and path[1] != expected:
            category_code = aliases.get(path[1].casefold())
            if category_code != current:
                risks.append({'kind': ('category_metadata_country_conflict' if category_code else
                                       'category_label_scope_difference'),
                              'categoryCountry': path[1], 'categoryCountryCode': category_code,
                              'metadataCountry': expected})
        for hint in edition_hints(channel, names, aliases):
            if current and hint['marketHint'] != current:
                risks.append(hint)
        if risks:
            findings.append({'channelId': channel['id'], 'name': channel['name'],
                             'countryCode': current, 'categoryPath': path,
                             'protected': channel['id'] in protected_ids,
                             'indicators': sorted(risks, key=lambda r: r['kind']),
                             'resolution': result['status']})
    return {'schemaVersion': 1, 'policyVersion': POLICY_VERSION,
            'catalogVersion': payload['version'], 'channelCount': len(payload['channels']),
            'routeCount': sum(len(c['routes']) for c in payload['channels']),
            'summary': dict(statuses), 'reviewFindingCount': len(findings),
            'findingKinds': dict(Counter(i['kind'] for f in findings for i in f['indicators'])),
            'proposedCorrections': results, 'reviewFindings': findings,
            'appliedChanges': 0, 'newEpgMappings': 0,
            'limitations': ['Indicator conflicts do not establish the correct replacement country',
                            'No evidence means unbound, not incorrectly classified',
                            'Reviewed registry currently covers one exact provider service',
                            'Private client classifications are outside this audit']}


def write_review_queue(payload, data_dir, manifest):
    """Refresh the persistent review queue after each catalog publication."""
    registry = json.loads(Path(__file__).with_name('broadcast_market_bindings.json').read_text())
    result = audit(payload, registry['bindings'])
    result.update(catalogSha256=manifest['sha256'], automaticApplyAllowed=False,
                  inventoryManualProtectionChecked=False)
    target = Path(data_dir) / 'broadcast-market-review-queue.json'
    fd, temporary = tempfile.mkstemp(prefix='.market-review-', dir=data_dir)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(result, output, ensure_ascii=False, separators=(',', ':'))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--bindings', type=Path, default=Path(__file__).with_name('broadcast_market_bindings.json'))
    parser.add_argument('--protected-ids', type=Path)
    args = parser.parse_args()
    protected = json.loads(args.protected_ids.read_text()) if args.protected_ids else []
    result = audit(json.loads(args.snapshot.read_text()),
                   json.loads(args.bindings.read_text())['bindings'], set(protected))
    result['inventoryManualProtectionChecked'] = args.protected_ids is not None
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps({key: result[key] for key in ('channelCount', 'routeCount', 'summary',
                      'reviewFindingCount', 'findingKinds', 'appliedChanges')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
