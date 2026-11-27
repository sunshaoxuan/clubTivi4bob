"""Build review candidates from the broadcasters' dated schedule directories."""
from datetime import date, datetime, time, timedelta
import json
import re
import unicodedata
from urllib.parse import parse_qs, urlencode, urlsplit
from xml.etree import ElementTree
from zoneinfo import ZoneInfo

SHANGHAI = ZoneInfo('Asia/Shanghai')
CCTV_NAMES = {'cctv1': 'CCTV-1 综合',
 'cctv2': 'CCTV-2 财经',
 'cctv3': 'CCTV-3 综艺',
 'cctv4': 'CCTV-4 (亚洲)',
 'cctv5': 'CCTV-5 体育',
 'cctv5plus': 'CCTV-5+ 体育赛事',
 'cctv6': 'CCTV-6 电影',
 'cctv7': 'CCTV-7 国防军事',
 'cctv8': 'CCTV-8 电视剧',
 'cctvjilu': 'CCTV-9 纪录',
 'cctv10': 'CCTV-10 科教',
 'cctv11': 'CCTV-11 戏曲',
 'cctv12': 'CCTV-12 社会与法',
 'cctv13': 'CCTV-13 新闻',
 'cctvchild': 'CCTV-14 少儿',
 'cctv15': 'CCTV-15 音乐',
 'cctv16': 'CCTV-16奥林匹克',
 'cctv17': 'CCTV-17农业农村',
 'cctveurope': 'CCTV-4 (欧洲)',
 'cctvamerica': 'CCTV-4 (美洲)'}
CNTV_NAMES = {**CCTV_NAMES, 'btv1': '北京卫视', 'gansu': '甘肃卫视'}
GUANGDONG = {'广东卫视': 1, '广东卫视4k': 34, '广东珠江': 2, '广东体育': 3,
             '广东民生': 4, '广东新闻': 6, '嘉佳卡通': 7,
             '大湾区卫视海外版': 8, '大湾区卫视': 14, '广东影视': 17, '广东少儿': 18}


def station_label(name):
    return re.sub(r'[\s_\-()（）]', '', unicodedata.normalize('NFKC', name).casefold())


CNTV = {station_label(label): code for code, label in CNTV_NAMES.items()}
CNTV.update({label: code for code, name in CCTV_NAMES.items()
             if (label := re.match(r'cctv\d+\+?', station_label(name)).group()) != 'cctv4'})
def schedule_urls(request, now):
    context = request['catalogueContext']
    if request['stage'] == 'identity' or context.get('countryCode') != 'CN':
        return []
    label = station_label(context.get('name') or '')
    day = datetime.fromtimestamp(now, SHANGHAI).date()
    dates = (day, day + timedelta(days=1))
    if label in CNTV:
        return ['https://api.cntv.cn/epg/getEpgInfoByChannelNew?' + urlencode(
            {'serviceId': 'tvcctv', 'c': CNTV[label], 'd': date.strftime('%Y%m%d')})
            for date in dates]
    if label in GUANGDONG:
        return [f'https://epg.gdtv.cn/f/{GUANGDONG[label]}/{date.isoformat()}.xml' for date in dates]
    return []


def add_candidates(request, evidence, urls, now):
    # The directory contributes leads, while the channel identity, grant and
    # publish checks remain with the existing review and ingestion pipeline.
    import epg_auto_search as search
    approved = [url for url in urls if search.candidate_allowed(
        url, request['domains'], request['stage'], request=request)]
    existing = {item['url']: item for item in evidence['candidates']}
    for url in approved:
        existing.setdefault(url, {'url': url, 'checkedAtUtc': now,
                                  'state': 'unverified_search_candidate',
                                  'engines': ['official_schedule_directory']})
    ordering = dict.fromkeys(approved + list(existing))
    evidence['candidates'] = [existing[url] for url in ordering][:20]
    evidence['officialScheduleDirectoryLeads'] = len(approved)


def inspect_schedule(url, raw, now):
    """Verify the source channel and date before counting factual intervals."""
    address = urlsplit(url)
    if address.hostname not in ('api.cntv.cn', 'epg.gdtv.cn'):
        return None
    from epg_ingest import decode, EpgError
    try:
        raw = decode(raw)
        if address.hostname == 'api.cntv.cn':
            if address.path != '/epg/getEpgInfoByChannelNew':
                return None
            query = parse_qs(address.query)
            channel, = query['c']
            day, = query['d']
            schedule_day = datetime.strptime(day, '%Y%m%d').date()
            roster = json.loads(raw)['data']
            if set(roster) != {channel} or roster[channel]['channelName'] != CNTV_NAMES[channel]:
                raise ValueError('source_channel_mismatch')
            rows = [(item['startTime'], item['endTime'], item['title']) for item in roster[channel]['list']]
        else:
            match = re.fullmatch(r'/f/(\d+)/(\d{4}-\d{2}-\d{2})\.xml', address.path)
            if match is None:
                return None
            channel, day = match.groups()
            schedule_day = date.fromisoformat(day)
            content = ElementTree.fromstring(raw)
            station = content.find('channel')
            if (station is None or station.attrib.get('id') != channel or station.findtext('cdate') != day
                    or GUANGDONG.get(station_label(station.findtext('ctitle') or '')) != int(channel)):
                raise ValueError('source_channel_or_date_mismatch')
            rows = [(item.attrib['time1'], item.attrib['time2'], item.text)
                    for item in content.findall('./epglist/content')]
        if not 0 < len(rows) <= 256:
            raise ValueError('source_schedule_size')
        start = datetime.combine(schedule_day, time.min, SHANGHAI).timestamp()
        end = start + 86400
        intervals = sorted({(int(a), int(b)) for a, b, title in rows if isinstance(title, str)
                            and title.strip() not in ('', '精彩节目', '普通节目', '节目预告', '节目回放')
                            and int(a) < end and int(b) > start and 0 < int(b) - int(a) <= 86400})
        if not intervals or any(a[1] > b[0] for a, b in zip(intervals, intervals[1:])):
            raise ValueError('source_schedule_empty_or_overlapping')
    except (EpgError, ValueError, KeyError, TypeError, AttributeError, ElementTree.ParseError):
        return {'result': 'official_schedule_requires_review', 'validIntervalRecords': 0,
                'contentInspectionVersion': 2, 'published': False}
    return {'result': 'programme_intervals_read_requires_feed_review',
            'contentInspectionVersion': 2, 'published': False, 'programmeIdentityApproved': False,
            'sourceChannelVerified': True, 'sourceDate': schedule_day.isoformat(),
            'validIntervalRecords': len(intervals),
            'currentIntervalRecords': sum(a <= now < b for a, b in intervals),
            'futureIntervalRecords': sum(a > now for a, _ in intervals)}
