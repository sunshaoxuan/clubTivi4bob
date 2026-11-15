"""Content evidence and bounded category paths shared by catalog workers."""
import hashlib
import re
import unicodedata
from urllib.parse import urlsplit

ROOTS = {"中国", "国际", "其他", "广播", "数字", "网络直播", "轮播", "点播"}
CONTENT_ROOTS = {"livestream": "网络直播", "loop": "轮播", "video": "点播"}
PLATFORMS = ("bilibili", "douyin", "douyu", "huya", "soop", "twitch", "yy", "kuaishou")
GENRES = (
    ("游戏", r"游戏|遊戲|电竞|電競|games?|gaming|英雄联盟|王者荣耀|穿越火线|和平精英|dota|counter.strike|云顶之弈"),
    ("动漫", r"动漫|動畫|动画|卡通|anime|animation|cartoons?"),
    ("剧集", r"电视剧|電視劇|剧集|連續劇|连续剧|series|drama"),
    ("电影", r"电影|電影|影厅|影院|movies?|cinema|films?"),
    ("音乐", r"音乐|音樂|music|演唱|歌唱|唱歌|钢琴|piano"),
    ("舞蹈", r"舞蹈|跳舞|dance|dancers?"),
    ("体育", r"体育|體育|sports?|football|basketball"),
    ("户外", r"户外|戶外|outdoors?|旅行|旅游|旅遊|travel"),
    ("知识", r"科普|知识|知識|教育|学习|學習|education|science"),
    ("纪录片", r"纪录|紀錄|documentar"),
    ("新闻", r"新闻|新聞|news"),
    ("生活", r"生活|lifestyle|cooking|美食|烹饪"),
    ("娱乐", r"娱乐|娛樂|综艺|綜藝|entertainment|variety"),
)
TOPICS = {label for label, _ in GENRES} | {'综合', '少儿', '儿童', '教育', '科普', '旅行', '美食',
    '文化', '喜剧', '财经', '汽车', '天气', '宗教', '购物', '公共事务', '经典', '家庭', '休闲', '互动', '公共', '成人'}


def valid_path(value):
    if not isinstance(value, str) or len(value) > 192:
        return False
    parts = value.split(' / ')
    return (1 <= len(parts) <= 8 and parts[0] in ROOTS
            and all(p == p.strip() and 1 <= len(p) <= 64
                    and not any(ord(c) < 32 for c in p) and '/' not in p and '\\' not in p
                    for p in parts))


def placeholder_url(url):
    p = urlsplit(url)
    return ((p.hostname or '').lower().startswith(('material.yang-1989.', 'epg.yang-1989.'))
            and bool(re.search(r'/v/(?:\d+|ban|limit)\.mp4$', p.path, re.I)))


def content_scope(name, group='', url=''):
    """Use explicit content/endpoint evidence, never a language-based country guess."""
    text = unicodedata.normalize('NFKC', f'{name} {group}').casefold()
    p = urlsplit(url)
    host = (p.hostname or '').lower()
    segments = [x for x in p.path.split('/') if x]
    platform = next((x for x in PLATFORMS if host == x + '.com' or host.endswith('.' + x + '.com')), None)
    room = None
    if host == 'cdn.ttvb.eu.org' and len(segments) >= 2 and segments[0] in PLATFORMS:
        platform, room = segments[:2]
    if platform and not room:
        room = p.path.rstrip('/') or '/'
    endpoint = hashlib.sha256(url.encode()).hexdigest() if url else None
    scope = f'{platform}:{room}' if platform else endpoint
    if re.search(r'轮播|輪播|循环播放|循環播放|\b(?:loop|24/7 movies)\b', text):
        return 'loop', scope
    if p.path.lower().endswith(('.mp4', '.mkv', '.avi', '.mov', '.webm')):
        return 'video', None
    if (platform or group.split(' / ')[0] == '网络直播'
            or re.search(r'网络直播|網絡直播|直播间|直播間|•(?:哔哩|抖音|斗鱼|虎牙|soop|twitch|歪歪)|游戏「赛事」', text)
            or host.endswith(('.bilivideo.com', '.douyucdn.cn', '.huya.com', '.acgvideo.com', '.kwimgs.com'))):
        return 'livestream', scope
    if (group.split(' / ')[0] == '广播' or re.search(r'广播|电台|電台|\bradio\b', text)
            or p.path.lower().endswith(('.aac', '.mp3', '.m4a', '.ogg', '.opus'))):
        return 'radio', None
    return 'television', None


def genre(name, groups):
    # Prefer explicit upstream topic labels to incidental words in a room name.
    for text in (groups, name):
        for label, pattern in GENRES:
            if re.search(pattern, text, re.I):
                return label
    return None


def semantic_path(value, name=''):
    """Accept a short semantic topic, not quality/provider/room labels as categories."""
    if not valid_path(value):
        return None
    parts = value.split(' / ')
    if len(parts) > 4:
        return None
    for part in parts[1:]:
        if (len(part) > 24 or part.casefold() == name.strip().casefold()
                or re.search(r'https?:|www\.|[\d@#?=]|高清|超清|移动|联通|电信|测试|订阅|订閱|资源|线路|\b(?:hd|uhd|fhd|hevc|h264|h265|iptv)\b', part, re.I)):
            return None
    topics = parts[2:] if parts[0] in ('中国', '国际') else parts[1:]
    if any(p not in TOPICS for p in topics): return None
    return value


def effective_scope(row, evidence=()):
    own = content_scope(row['name'], row['group_name'], row['url'])
    explicit = [content_scope(row['name'], group, row['url']) for group in evidence]
    # An explicit loop label distinguishes a platform's movie loop from a room.
    return next((scope for scope in explicit if scope[0] == 'loop'), own)


def automatic_group(name, group, kind, country, region, countries, provinces, evidence=()):
    groups = [group, *evidence]
    if kind in CONTENT_ROOTS:
        root = CONTENT_ROOTS[kind]
        explicit = [semantic_path(g, name) for g in groups if g.split(' / ')[0] == root]
        return next((g for g in explicit if g and len(g.split(' / ')) > 1),
                    root + ' / ' + (genre(name, ' '.join(groups)) or '综合'))
    if kind == 'radio':
        return '广播'
    # Structured canonical paths are useful evidence; raw provider groups are not.
    for candidate in groups:
        safe = semantic_path(candidate, name)
        if not safe:
            continue
        parts = safe.split(' / ')
        if parts[0] == '国际' and len(parts) > 1 and parts[1] in countries.values():
            code = next(k for k, label in countries.items() if label == parts[1])
            if not country or country == code:
                return safe
        if parts[0] == '中国' and len(parts) > 1 and country in (None, 'CN'):
            if parts[1] in {*provinces, '央视', '卫视', '数字'}:
                return safe
        if parts[0] == '数字':
            return safe
    return None


def declared_country(groups, countries):
    found = set()
    for group in groups:
        if not valid_path(group):
            continue
        parts = group.split(' / ')
        if parts[0] == '中国':
            found.add('CN')
        elif parts[0] == '国际' and len(parts) > 1:
            found.update(k for k, v in countries.items() if v == parts[1])
    return next(iter(found)) if len(found) == 1 else None
