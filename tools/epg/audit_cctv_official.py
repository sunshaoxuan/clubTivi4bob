"""Check two days for the reviewed CCTV services and print evidence counts."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'website'))

from epg_cctv import RESEARCH_NAMES, ZONE, fetch_schedule, parse_schedule
from epg_ingest import EpgError


def read(job):
    channel, day, checked_at = job
    evidence = {'sourceChannelId': channel, 'sourceDay': day}
    try:
        body, metadata = fetch_schedule(channel, day, research=True)
        result = parse_schedule(body, channel, day, checked_at, research=True)
        quality = result['quality']
        return {**evidence, 'state': 'read' if quality['acceptedProgrammes'] else 'no_usable_rows',
                'identity': result['identity'], 'quality': quality, **metadata}
    except EpgError as error:
        return {**evidence, 'state': 'pending_review', 'reason': str(error)}
    except (OSError, ValueError):
        return {**evidence, 'state': 'pending_review', 'reason': 'source_unavailable'}


def main():
    checked_at = datetime.now(ZONE)
    days = [(checked_at.date() + timedelta(days=offset)).strftime('%Y%m%d') for offset in (0, 1)]
    jobs = [(channel, day, int(checked_at.timestamp())) for channel in RESEARCH_NAMES for day in days]
    with ThreadPoolExecutor(max_workers=4) as pool:
        receipts = list(pool.map(read, jobs))
    qualities = {(r['sourceChannelId'], r['sourceDay']): r.get('quality', {}) for r in receipts}
    confirmed = [channel for channel in RESEARCH_NAMES
                 if qualities[channel, days[0]].get('currentAndFutureChannels')
                 and qualities[channel, days[1]].get('futureChannels')]
    print(json.dumps({'checkedAt': checked_at.isoformat(timespec='seconds'),
        'calendarTimezone': ZONE.key, 'days': days, 'servicesChecked': len(RESEARCH_NAMES),
        'servicesWithCurrentAndNextDay': confirmed,
        'approvedCatalogMappings': 0, 'publicCoverageAdded': 0, 'checks': receipts},
        ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
