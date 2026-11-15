"""Persistent channel identities and conservative background route matching."""
import hashlib
import json
import re
import unicodedata
from pathlib import Path
from channel_taxonomy import ROOTS, automatic_group, content_scope, declared_country, effective_scope, genre, valid_path
from channel_reference import load as load_reference

RULES = json.loads(Path(__file__).with_name("channel_classification_rules.json").read_text(encoding="utf-8"))
COUNTRIES = {key.upper(): value for key, value in RULES["countries"].items()}
COUNTRIES["CN"] = "中国"
ALIASES = {
    "beijingtv": "北京卫视", "beijingsatellite": "北京卫视", "btv1": "北京卫视",
    "北京卫视": "北京卫视", "hunantv": "湖南卫视", "hunansatellite": "湖南卫视",
    "湖南卫视": "湖南卫视", "zhejiangtv": "浙江卫视",
    "zhejiangsatellite": "浙江卫视", "浙江卫视": "浙江卫视",
    "bbc1": "bbcone", "bbcone": "bbcone", "bbc2": "bbctwo", "bbctwo": "bbctwo",
    "翡翠台": "翡翠台", "翡翠": "翡翠台", "tvbjade": "翡翠台",
}


def migrate(conn):
    # The caller owns commit/rollback; SQLite DDL participates in this transaction.
    if not conn.in_transaction:
        # Preserve the deployed WAL read path while a catalog worker writes.
        required = {'public_sources_v1', 'channel_ai_v1', 'channel_matching_v1'}
        applied = {row[0] for row in conn.execute(
            "SELECT name FROM catalog_migrations WHERE name IN "
            "('public_sources_v1','channel_ai_v1','channel_matching_v1')")}
        if required <= applied:
            return
        conn.execute("BEGIN IMMEDIATE")
    if not conn.execute("SELECT 1 FROM catalog_migrations WHERE name='public_sources_v1'").fetchone():
        conn.execute("CREATE TABLE public_source_routes (source_id TEXT NOT NULL, digest TEXT NOT NULL, url TEXT NOT NULL, name TEXT NOT NULL, group_name TEXT NOT NULL, access TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(source_id,digest))")
        conn.execute("CREATE INDEX public_source_route_digest ON public_source_routes(digest)")
        conn.execute("CREATE TABLE public_source_refreshes (source_id TEXT PRIMARY KEY, attempted_at INTEGER NOT NULL, succeeded_at INTEGER, status TEXT NOT NULL, discovered INTEGER NOT NULL, retained INTEGER NOT NULL, skipped INTEGER NOT NULL)")
        conn.execute("INSERT INTO catalog_migrations VALUES ('public_sources_v1')")
    if not conn.execute("SELECT 1 FROM catalog_migrations WHERE name='channel_ai_v1'").fetchone():
        conn.execute("CREATE TABLE catalog_ai_decisions (digest TEXT PRIMARY KEY, signature TEXT NOT NULL, request_id TEXT NOT NULL, state TEXT NOT NULL, response TEXT, attempts INTEGER NOT NULL, attempted_at INTEGER NOT NULL, retry_at INTEGER NOT NULL, model TEXT NOT NULL, error_code TEXT)")
        conn.execute("CREATE INDEX catalog_ai_retry ON catalog_ai_decisions(state,retry_at)")
        conn.execute("INSERT INTO catalog_migrations VALUES ('channel_ai_v1')")
    if conn.execute("SELECT 1 FROM catalog_migrations WHERE name='channel_matching_v1'").fetchone():
        return
    columns = {row[1] for row in conn.execute("PRAGMA table_info(routes)")}
    for name, definition in {"manual_name": "INTEGER NOT NULL DEFAULT 0", "merge_id": "TEXT",
                             "transferred": "INTEGER NOT NULL DEFAULT 0"}.items():
        if name not in columns:
            conn.execute(f"ALTER TABLE routes ADD COLUMN {name} {definition}")
    conn.execute("CREATE TABLE catalog_channels (id TEXT PRIMARY KEY, metadata TEXT NOT NULL, group_name TEXT NOT NULL, profile TEXT NOT NULL)")
    conn.execute("CREATE TABLE catalog_channel_routes (digest TEXT PRIMARY KEY, channel_id TEXT, state TEXT NOT NULL, reason TEXT NOT NULL, signature TEXT NOT NULL)")
    conn.execute("CREATE INDEX catalog_channel_members ON catalog_channel_routes(channel_id)")
    conn.execute("INSERT INTO catalog_migrations VALUES ('channel_matching_v1')")


def clean_name(value):
    value = unicodedata.normalize("NFKC", value or "").strip()
    value = re.sub(r"\s*\[(?:Geo-blocked|Not 24/7)\]", "", value, flags=re.I)
    value = re.sub(r"\s*\((?:\d{3,4}p|HD|SD|FHD)\)", "", value, flags=re.I)
    value = re.sub(r"^(CCTV[\s_-]*\d{1,2}\+?)(?:HD|FHD|SD)$", r"\1", value, flags=re.I)
    return re.sub(r"(?:[\s_-]+|(?<=[\u3400-\u9fff]))(?:HD|FHD|SD|1080P|720P|高清|超清|标清)$", "", value, flags=re.I).strip()


def name_key(value):
    value = clean_name(value).casefold()
    central = re.match(r"^(?:cctv|央视|中央电视台)[\s_-]*0*(\d{1,2})(\+)?(?=$|[\s_.-]|[\u3400-\u9fff])", value)
    if central:
        quality = re.search(r"(?<![a-z0-9])([48]k)(?![a-z0-9])", value)
        return "cctv" + str(int(central[1])) + (central[2] or "") + (quality[1] if quality else "")
    value = re.sub(r"[\s_-]+", "", value)
    return ALIASES.get(value, value)


def valid_group(value):
    if not valid_path(value):
        return "其他 / 待识别"
    return value


def _term(text, term):
    if re.fullmatch(r"[a-z]+", term):
        return re.search(r"(?<![a-z])" + re.escape(term) + r"(?![a-z])", text, re.I) is not None
    return term.casefold() in text


def profile(name, epg=None, group="", country=None, region=None, trusted=False, url="", countries=COUNTRIES):
    display = clean_name(name)
    epg = unicodedata.normalize("NFKC", epg or "").strip().casefold()
    epg = re.sub(r"@(?:sd|hd|fhd)$", "", epg)
    qualified = re.fullmatch(r"(.+)\.([a-z]{2})(?:@(.+))?", epg)
    epg_country = qualified[2].upper() if qualified else None
    if epg_country == "UK": epg_country = "GB"
    if epg_country not in countries: epg_country = None
    epg_key = name_key(qualified[1] if qualified else epg)
    key = name_key(display)
    identity = display.casefold() + " " + key
    province = None
    hits = [(len(term), p) for p, terms in RULES["provinces"].items()
            for term in terms if _term(identity, term)]
    if hits:
        province = max(hits)[1]
    inferred = "CN" if province or re.match(r"^(?:cctv|cgtn)", key) else "HK" if key == "翡翠台" else None
    declared = (country or "").upper() or None
    if trusted and not declared:
        parts = group.split(" / ")
        if parts[0] == "中国": declared = "CN"
        elif len(parts) > 1 and parts[0] == "国际":
            declared = next((code for code, label in countries.items() if label == parts[1]), None)
    country = epg_country or inferred or declared
    conflict = bool(len({x for x in (epg_country, inferred, declared) if x}) > 1)
    variant_text = (display + " " + epg).casefold()
    variants = sorted(set(re.findall(r"(?<![a-z0-9])(?:[48]k|uhd)(?![a-z0-9])|\+\d+|\b(?:english|french|spanish|arabic|mandarin|cantonese)\b|英语|法语|西语|粤语|国语", variant_text)))
    if qualified and qualified[3] and qualified[3] not in ('4k', '8k', 'uhd'):
        variants.append('epg:' + qualified[3])
    # CCTV-5+ is the station identity; +1 remains a distinct time-shift feed.
    kind, scope = content_scope(display, group, url)
    return {"name": key, "epg": epg_key, "country": country, "region": region or province,
            "variant": variants, "conflict": conflict, "qualified": bool(epg_country),
            "kind": kind, "scope": scope}


def classify(row, p, evidence=(), countries=COUNTRIES, topics=()):
    if row["manual_category"]:
        return valid_group(row["group_name"])
    topic = next(iter(topics), None) or genre(row['name'], ' '.join([row['group_name'], *evidence]))
    proposed = automatic_group(row['name'], row['group_name'], p['kind'], p['country'],
                               p['region'], countries, RULES['provinces'], evidence)
    if proposed:
        if proposed.startswith('国际 / ') and len(proposed.split(' / ')) == 2 and topic:
            return proposed + ' / ' + topic
        return proposed
    if p["country"] == "CN":
        if re.match(r"^(?:cctv|cgtn)", p["name"]): return "中国 / 央视"
        if p["region"] in RULES["provinces"]: return "中国 / " + p["region"]
        return "中国 / 未识别地区"
    if p["country"] in countries:
        return "国际 / " + countries[p["country"]] + (' / ' + topic if topic else '')
    text = row["name"].casefold()
    if any(_term(text, t) for t in ("广播", "电台", "radio")): return "广播"
    if any(_term(text, t) for t in RULES["digital"]): return "数字"
    if topic: return '其他 / ' + topic
    existing = valid_group(row["group_name"])
    return existing if existing.split(" / ")[0] != "其他" else "其他 / 待识别"


def _compatible(left, right):
    return (not left["conflict"] and not right["conflict"]
            and left['kind'] == right['kind'] and left['scope'] == right['scope']
            and left["variant"] == right["variant"]
            and all(not left[k] or not right[k] or left[k] == right[k] for k in ("country", "region")))


def _signature(row, evidence=()):
    fields = ("name", "group_name", "epg_id", "manual_category", "manual_name", "merge_id", "transferred")
    return hashlib.sha256(json.dumps([*[row[f] for f in fields],
        effective_scope(row, evidence), sorted(set(evidence))], ensure_ascii=False).encode()).hexdigest()


def _evidence_profile(row, evidence, reference, countries):
    # A qualified EPG is stronger than an old automatic category. Manual paths
    # still participate in conflict checks, as do explicit geographic names.
    p = profile(row['name'], row['epg_id'], url=row['url'], countries=countries)
    declared = declared_country([row['group_name'], *evidence], countries)
    if row['manual_category'] or not p['qualified']:
        p = profile(row['name'], row['epg_id'], row['group_name'], country=declared,
                    trusted=bool(row['manual_category']), url=row['url'], countries=countries)
    p['kind'], p['scope'] = effective_scope(row, evidence)
    known = reference.lookup(row['name'], row['epg_id'], p['country'])
    if known and not p['conflict']:
        # A legacy automatic radio group alone cannot turn a known TV station
        # into a radio station. Explicit audio names/endpoints remain radio.
        if (p['kind'] == 'radio' and not row['manual_category']
                and content_scope(row['name'], '', row['url'])[0] == 'television'):
            p['kind'], p['scope'] = 'television', None
        if p['kind'] == 'television': p['country'] = known['country']
    return p, known if p['kind'] == 'television' else None


def _migrate_taxonomy(conn, reference, countries):
    if conn.execute("SELECT 1 FROM catalog_migrations WHERE name='channel_taxonomy_v1'").fetchone():
        return
    evidence = {}
    for r in conn.execute('SELECT digest,group_name FROM public_source_routes WHERE active=1 ORDER BY source_id'):
        evidence.setdefault(r['digest'], []).append(r['group_name'])
    for entity in conn.execute('SELECT id,profile,metadata,group_name FROM catalog_channels').fetchall():
        p = json.loads(entity['profile'])
        rows = conn.execute('SELECT r.* FROM routes r JOIN catalog_channel_routes m ON m.digest=r.digest '
            'WHERE m.channel_id=? AND r.blocked=0 AND r.deleted=0', (entity['id'],)).fetchall()
        candidates = [(r, _evidence_profile(r, evidence.get(r['digest'], ()), reference, countries)[0]) for r in rows]
        published = [(r, q) for r, q in candidates if r['success_at'] is not None]
        candidates = published or candidates
        scopes = {(q['kind'], q['scope']) for _, q in candidates}
        # Mixed historical identities keep the television card; distinct rooms
        # are separated by the ordinary matcher on this first versioned pass.
        kind, scope = (next(iter(scopes)) if len(scopes) == 1 else
                       ('television', None) if ('television', None) in scopes else
                       min(scopes, key=str) if scopes else content_scope('', entity['group_name']))
        p.update(kind=kind, scope=scope)
        metadata = json.loads(entity['metadata'])
        if rows and not any(r['manual_name'] or r['manual_category'] for r in rows):
            compatible = [(r, q) for r, q in candidates if not q['conflict'] and (q['kind'], q['scope']) == (kind, scope)]
            if compatible:
                row, candidate = min(compatible, key=lambda rq: (
                    rq[1]['name'] != p['name'], not rq[1]['qualified'], rq[0]['digest']))
                p.update(country=candidate['country'] or p['country'], region=candidate['region'] or p['region'], conflict=False,
                         epg=candidate['epg'], qualified=candidate['qualified'], variant=candidate['variant'])
                metadata.update(countryCode=p['country'], regionCode=p['region'], epgId=row['epg_id'] or metadata['epgId'])
                epg_profile = profile('', metadata['epgId'], countries=countries)
                if epg_profile['country'] and p['country'] and epg_profile['country'] != p['country']:
                    metadata['epgId'] = row['epg_id']
                canonical = profile(metadata['name'], metadata['epgId'], countries=countries)
                if canonical['variant'] != candidate['variant']:
                    metadata['name'] = clean_name(row['name'])
                    p['name'] = name_key(metadata['name'])
        conn.execute('UPDATE catalog_channels SET profile=?,metadata=? WHERE id=?',
                     (json.dumps(p), json.dumps(metadata, ensure_ascii=False), entity['id']))
    fields = ('name', 'group_name', 'epg_id', 'manual_category', 'manual_name', 'merge_id', 'transferred')
    for row in conn.execute('SELECT r.*,m.signature AS old_signature FROM routes r JOIN catalog_channel_routes m USING(digest)').fetchall():
        legacy = hashlib.sha256(json.dumps([row[f] for f in fields], ensure_ascii=False).encode()).hexdigest()
        if row['old_signature'] == legacy:
            conn.execute('UPDATE catalog_channel_routes SET signature=? WHERE digest=?',
                         (_signature(row, evidence.get(row['digest'], ())), row['digest']))
    # Old responses lack the room-scope signature and must be reconsidered.
    conn.execute("UPDATE catalog_ai_decisions SET state='superseded',retry_at=0,response=NULL,error_code='taxonomy_upgrade'")
    conn.execute("INSERT INTO catalog_migrations VALUES ('channel_taxonomy_v1')")


def _path(category_id, categories):
    parts = []
    while category_id:
        item = categories[category_id]
        parts.insert(0, item["name"])
        category_id = item["parentId"]
    return " / ".join(parts)


class Matcher:
    def __init__(self, conn, current):
        migrate(conn)
        self.conn = conn
        self.reference = load_reference(Path(conn.execute('PRAGMA database_list').fetchone()[2]).parent)
        self.countries = {**self.reference.countries, **COUNTRIES}
        if current:
            categories = {c["id"]: c for c in current["categories"]}
            for channel in current["channels"]:
                group = _path(channel["categoryId"], categories)
                metadata = {k: v for k, v in channel.items() if k != "routes"}
                p = profile(channel["name"], channel["epgId"], group, channel["countryCode"], channel["regionCode"], True)
                conn.execute("INSERT OR IGNORE INTO catalog_channels VALUES (?,?,?,?)", (channel["id"], json.dumps(metadata, ensure_ascii=False), group, json.dumps(p)))
                for route in channel["routes"]:
                    digest = hashlib.sha256(route["url"].encode()).hexdigest()
                    conn.execute("INSERT OR IGNORE INTO catalog_channel_routes VALUES (?,?,'assigned','published','')", (digest, channel["id"]))
        _migrate_taxonomy(conn, self.reference, self.countries)
        self.entities = {r["id"]: {"metadata": json.loads(r["metadata"]), "group": r["group_name"], "profile": json.loads(r["profile"])} for r in conn.execute("SELECT * FROM catalog_channels ORDER BY id")}
        self.pending_ids = {r[0] for r in conn.execute("SELECT channel_id FROM catalog_channel_routes GROUP BY channel_id HAVING sum(state='assigned')=0")}
        self.names, self.epgs, self.merges = {}, {}, {}
        for identity, entity in self.entities.items():
            self._index(identity, entity["profile"])
            if entity["metadata"].get("mergeId"):
                self.merges[entity["metadata"]["mergeId"]] = identity
        self.assignments = {r["digest"]: dict(r) for r in conn.execute("SELECT * FROM catalog_channel_routes")}
        self.ai_decisions = {r["digest"]: dict(r) for r in conn.execute("SELECT digest,signature,response FROM catalog_ai_decisions WHERE state='accepted'")}
        self.manual_channels = {r[0] for r in conn.execute(
            'SELECT DISTINCT m.channel_id FROM catalog_channel_routes m JOIN routes r ON r.digest=m.digest '
            'WHERE r.manual_category=1 AND r.blocked=0 AND r.deleted=0')}
        self.manual_names = {r[0] for r in conn.execute(
            'SELECT DISTINCT m.channel_id FROM catalog_channel_routes m JOIN routes r ON r.digest=m.digest '
            'WHERE r.manual_name=1 AND r.blocked=0 AND r.deleted=0')}
        self.category_evidence = {}
        self.group_proposals = {}
        for r in conn.execute('SELECT digest,group_name FROM public_source_routes WHERE active=1 ORDER BY source_id'):
            self.category_evidence.setdefault(r['digest'], []).append(r['group_name'])
        # Previously accepted aliases are indexed only with the entity's scope.
        for row in conn.execute("SELECT r.*,m.channel_id,m.signature AS match_signature FROM routes r JOIN catalog_channel_routes m ON m.digest=r.digest WHERE m.state='assigned' AND r.blocked=0 AND r.deleted=0"):
            if row["match_signature"] not in ("", _signature(row, self.category_evidence.get(row['digest'], ()))): continue
            entity = self.entities[row["channel_id"]]
            p = profile(row["name"], row["epg_id"], row['group_name'], url=row['url'])
            if _compatible(p, entity["profile"]): self._index(row["channel_id"], p)

    def _index(self, identity, p):
        if identity in self.pending_ids: return
        if p["name"]: self.names.setdefault(p["name"], set()).add(identity)
        if p["epg"]: self.epgs.setdefault(p["epg"], set()).add(identity)

    def _save_entity(self, identity, metadata, group, p):
        self.conn.execute("INSERT INTO catalog_channels VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata,group_name=excluded.group_name,profile=excluded.profile", (identity, json.dumps(metadata, ensure_ascii=False), group, json.dumps(p)))
        self.entities[identity] = {"metadata": metadata, "group": group, "profile": p}
        self._index(identity, p)
        if metadata.get("mergeId"): self.merges[metadata["mergeId"]] = identity

    def resolve(self, row):
        evidence = self.category_evidence.get(row['digest'], ())
        signature = _signature(row, evidence)
        saved = self.assignments.get(row["digest"])
        p, reference = _evidence_profile(row, evidence, self.reference, self.countries)
        identity, reason, ai_group = None, "insufficient-evidence", None
        if (saved and saved['state'] == 'pending' and not p['conflict'] and
                (p['country'] or p['scope']) and _compatible(p, self.entities[saved['channel_id']]['profile'])):
            identity, reason = saved['channel_id'], 'identified-existing-card'
            self.pending_ids.discard(identity)
        if row["merge_id"]:
            identity = self.merges.get(row["merge_id"])
            if identity is None:
                identity = "channel-" + hashlib.sha256((row["merge_id"] + "\n" + row["group_name"]).encode()).hexdigest()[:24]
            reason = "manual-merge"
        elif saved and saved["state"] == "assigned" and (saved["signature"] in ("", signature) or not row["transferred"]):
            previous = self.entities[saved["channel_id"]]
            if row['manual_name'] and not row['transferred']:
                # A display-name correction does not change the assigned feed.
                p = dict(previous['profile'])
            elif row['manual_category']:
                p['kind'], p['scope'] = previous['profile']['kind'], previous['profile']['scope']
            if (_compatible(p, previous['profile']) and (saved["signature"] in ("", signature)
                    or row["manual_name"] or p["name"] == previous["profile"]["name"])):
                identity, reason = saved["channel_id"], "existing-assignment"
                if not p['country']: p['country'] = previous['profile']['country']
                if not p['region']: p['region'] = previous['profile']['region']
        if identity is None and not p["conflict"]:
            named = {i for i in self.names.get(p["name"], set()) if _compatible(p, self.entities[i]["profile"])}
            epgs = {i for i in self.epgs.get(p["epg"], set()) if _compatible(p, self.entities[i]["profile"])} if p["epg"] else set()
            both = named & epgs
            choices = both if both else epgs if p["qualified"] else named
            if len(choices) == 1:
                candidate = next(iter(choices))
                target = self.entities[candidate]["profile"]
                conflict = p["epg"] and target["epg"] and p["epg"] != target["epg"]
                if conflict:
                    reason = "conflicting-epg"
                elif p["country"] or p['scope'] or (both and p["epg"]):
                    identity, reason = candidate, "epg" if candidate in epgs else "name-alias"
            elif len(choices) > 1:
                reason = "ambiguous-match"
            elif p["country"] or p['scope'] or row["manual_category"] or row["manual_name"]:
                identity = (saved['channel_id'] if saved and saved['channel_id'] in self.pending_ids
                            and _compatible(p, self.entities[saved['channel_id']]['profile']) else
                            "channel-" + hashlib.sha256(json.dumps(["identity-v1", p], sort_keys=True).encode()).hexdigest()[:24])
                self.pending_ids.discard(identity)
                reason = "new-channel"
        if p["conflict"] and identity is None: reason = "conflicting-scope"
        if identity not in self.manual_channels and identity not in self.manual_names:
            decision = self.ai_decisions.get(row["digest"])
            if decision and decision["signature"] == signature and not any(row[k] for k in ("manual_name", "manual_category", "merge_id", "transferred")):
                from channel_ai_matching import accepted_identity
                accepted = accepted_identity(self, row, json.loads(decision["response"]))
                if accepted:
                    identity, p, group, display = accepted
                    if identity not in self.entities or identity in self.pending_ids or self.entities[identity]['group'].startswith('其他'):
                        previous = self.entities.get(identity)
                        metadata = dict(previous["metadata"]) if previous else dict(id=identity, categoryId="", sortOrder=len(self.entities), logoUrl=None)
                        metadata.update(name=display, epgId=row["epg_id"], countryCode=p["country"], regionCode=p["region"])
                        self.pending_ids.discard(identity)
                        self._save_entity(identity, metadata, group, p)
                    ai_group = group
                    reason = "ai-match"
        unresolved = identity is None
        if unresolved:
            previous = self.entities.get(saved['channel_id']) if saved else None
            same_content = (previous and p['kind'] == previous['profile']['kind']
                            and p['scope'] == previous['profile']['scope'] and p['variant'] == previous['profile']['variant'])
            identity = saved['channel_id'] if same_content else "channel-" + hashlib.sha256(("pending-v1\n" + row["digest"]).encode()).hexdigest()[:24]
            self.pending_ids.add(identity)
        if identity:
            entity = self.entities.get(identity)
            group = ai_group or classify(row, p, evidence, self.countries, reference['topics'] if reference else ())
            if not row['manual_category'] and identity not in self.manual_channels and group not in ('其他', '其他 / 待识别'):
                proposals = self.group_proposals.setdefault(identity, set())
                proposals.add(group)
                group = min(proposals, key=lambda g: (g.startswith('其他'), -len(g.split(' / ')), g))
            if entity:
                metadata = dict(entity["metadata"])
                if row["manual_category"]:
                    entity["group"] = group
                    self.manual_channels.add(identity)
                elif identity not in self.manual_channels and group not in ('其他', '其他 / 待识别'):
                    entity['group'] = group
                if not metadata['countryCode'] and p['country']: metadata['countryCode'] = p['country']
                if row["manual_name"]:
                    metadata["name"] = row["name"]
                    self.manual_names.add(identity)
                if not metadata["epgId"] and row["epg_id"]: metadata["epgId"] = row["epg_id"]
                if (p['qualified'] and not p['conflict'] and identity not in self.manual_names
                        and identity not in self.manual_channels):
                    old_epg = profile('', metadata['epgId'], countries=self.countries)
                    if old_epg['country'] and old_epg['country'] != p['country']:
                        metadata['epgId'] = row['epg_id']
                if row["merge_id"]: metadata["mergeId"] = row["merge_id"]
                updated = profile(metadata["name"], metadata["epgId"], entity["group"], metadata["countryCode"], metadata["regionCode"], True, row['url'], self.countries)
                updated['kind'], updated['scope'] = p['kind'], p['scope']
                if identity in self.manual_names and not row['transferred']:
                    updated = dict(entity['profile'])
                if not metadata['countryCode'] and not updated['conflict']:
                    metadata['countryCode'] = updated['country']
                self._save_entity(identity, metadata, entity["group"], updated)
            else:
                name = row["name"] if row["manual_name"] else clean_name(row["name"])
                central = re.fullmatch(r"cctv(\d+)(\+)?([48]k)?", p["name"])
                if central and not row["manual_name"]:
                    name = "CCTV-" + central[1] + (central[2] or "") + (" " + central[3].upper() if central[3] else "")
                metadata = dict(id=identity, name=name, categoryId="", countryCode=p["country"], regionCode=p["region"], sortOrder=len(self.entities), epgId=row["epg_id"], logoUrl=None)
                if row["merge_id"]: metadata["mergeId"] = row["merge_id"]
                self._save_entity(identity, metadata, group, p)
                if row['manual_category']: self.manual_channels.add(identity)
            self._index(identity, p)
        state = "pending" if unresolved else "assigned"
        self.conn.execute("INSERT INTO catalog_channel_routes VALUES (?,?,?,?,?) ON CONFLICT(digest) DO UPDATE SET channel_id=excluded.channel_id,state=excluded.state,reason=excluded.reason,signature=excluded.signature", (row["digest"], identity, state, reason, signature))
        self.assignments[row["digest"]] = dict(channel_id=identity, state=state, reason=reason, signature=signature)
        return identity
