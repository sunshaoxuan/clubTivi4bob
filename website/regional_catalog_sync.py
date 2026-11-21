"""Account-only regional snapshots. The existing publication remains the input."""
import base64
import gzip
import hashlib
import json
import os
import re
import secrets
import time
from functools import lru_cache
from pathlib import Path
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

import accounts
import channel_catalog

router = APIRouter(prefix='/api/v1/regional-catalog')
NS = 'bobtv-regional-catalog-v1'
NO_CACHE = {'Cache-Control':'private, no-store', 'Vary':'Authorization'}
REGION = re.compile(r'[A-Z]{2}')
HASH = re.compile(r'[a-f0-9]{64}')


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',',':'),sort_keys=True).encode('utf-8')


def b64(value):
    return base64.urlsafe_b64encode(value).decode().rstrip('=')


def unb64(value, length):
    try:
        raw = base64.urlsafe_b64decode(value + '=' * (-len(value) % 4))
        if len(raw) != length or b64(raw) != value:
            raise ValueError()
        return raw
    except (ValueError, TypeError):
        raise HTTPException(422,'invalid_catalog_key_material') from None


def signing_key():
    path = os.environ.get('BOBTV_REGIONAL_CATALOG_SIGNING_KEY')
    if not path:
        raise HTTPException(503,'regional_catalog_unconfigured')
    try:
        with open(path,'rb') as key_file:
            seed = key_file.read(33)
        return Ed25519PrivateKey.from_private_bytes(seed)
    except (OSError,ValueError):
        raise HTTPException(503,'regional_catalog_unconfigured') from None


def package_metadata(key):
    public = key.public_key().public_bytes_raw()
    return dict(apiBase=accounts.origin()+'/api/v1/regional-catalog',
                publicKey=b64(public),keyId=hashlib.sha256(public).hexdigest(),
                algorithm='Ed25519',schemaVersion=1)


def envelope(key, payload):
    body = encoded(payload)
    return dict(payload=b64(body), signature=b64(key.sign(body)))


def member(request):
    token=request.headers.get('authorization','')
    if not token.startswith('Bearer '):
        raise HTTPException(401,'login_required')
    user=accounts.current(request)
    if not user['verified']:
        raise HTTPException(403,'verified_account_required')
    return user,accounts.digest(token[7:])


class ChallengeRequest(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    publicKey: str = Field(pattern=r'^[A-Za-z0-9_-]{43}$')
    action: str = Field(pattern=r'^(enroll|regions|sync|revoke)$')
    region: Optional[str] = Field(default=None,pattern=r'^[A-Z]{2}$')
    knownRevision: Optional[str] = Field(default=None,pattern=r'^[a-f0-9]{64}$')


class Proof(BaseModel):
    model_config=ConfigDict(extra='forbid',strict=True)
    nonce: str = Field(pattern=r'^[A-Za-z0-9_-]{43}$')
    signature: str = Field(pattern=r'^[A-Za-z0-9_-]{86}$')


def tables(db):
    db.executescript('''
    CREATE TABLE IF NOT EXISTS regional_devices (
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      public_key TEXT NOT NULL, created INT NOT NULL, PRIMARY KEY(user_id,public_key));
    CREATE TABLE IF NOT EXISTS regional_challenges (
      nonce TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      session_hash TEXT NOT NULL, expires INT NOT NULL, claims BLOB NOT NULL);
    CREATE INDEX IF NOT EXISTS regional_challenges_expiry ON regional_challenges(expires);
    ''')


@router.get('/bootstrap.bobtv')
def bootstrap():
    key=signing_key()
    meta=package_metadata(key)
    # A bootstrap can be shared safely. No production route addresses are embedded.
    return JSONResponse(dict(format='bobtv-sync-bootstrap',**meta),
        headers={**NO_CACHE,'Content-Disposition':'attachment; filename="BobTV.bobtv"'})


@router.post('/challenge')
def issue_challenge(body: ChallengeRequest, request: Request):
    user,session=member(request)
    key=signing_key()
    if (body.action=='sync') != bool(body.region) or (body.knownRevision and body.action!='sync'):
        raise HTTPException(422,'invalid_catalog_scope')
    unb64(body.publicKey,32)
    now=int(time.time())
    if body.action=='enroll' and now-user['authenticated_at']>600:
        raise HTTPException(403,'recent_login_required')
    accounts.throttle('regional:challenge:'+user['id'],30,60)
    nonce=secrets.token_urlsafe(32)
    claims=encoded(dict(domain=NS,origin=accounts.origin(),userId=user['id'],
                        nonce=nonce,expires=now+90,**body.model_dump()))
    with accounts.database() as db:
        tables(db)
        db.execute('BEGIN IMMEDIATE')
        db.execute('DELETE FROM regional_challenges WHERE expires<=?',(now,))
        if body.action!='enroll' and not db.execute(
                'SELECT 1 FROM regional_devices WHERE user_id=? AND public_key=?',
                (user['id'],body.publicKey)).fetchone():
            raise HTTPException(403,'device_not_registered')
        db.execute('INSERT INTO regional_challenges VALUES (?,?,?,?,?)',
                   (nonce,user['id'],session,now+90,claims))
    return JSONResponse(envelope(key,json.loads(claims)),headers=NO_CACHE)


def consume(request, proof):
    user,session=member(request)
    now=int(time.time())
    signature=unb64(proof.signature,64)
    with accounts.database() as db:
        tables(db)
        db.execute('BEGIN IMMEDIATE')
        # Recheck session in the same transaction that consumes the proof.
        row=db.execute('''SELECT c.claims, s.created FROM regional_challenges c JOIN sessions s
            ON s.token_hash=c.session_hash AND s.user_id=c.user_id
            JOIN users u ON u.id=c.user_id WHERE c.nonce=? AND c.user_id=? AND c.session_hash=?
            AND c.expires>? AND s.expires>? AND u.disabled=0 AND u.verified=1''',
            (proof.nonce,user['id'],session,now,now)).fetchone()
        if not row:
            raise HTTPException(403,'invalid_or_used_catalog_challenge')
        raw=row['claims']
        claims=json.loads(raw)
        public_key=claims['publicKey']
        try:
            Ed25519PublicKey.from_public_bytes(unb64(public_key,32)).verify(signature,raw)
        except InvalidSignature:
            raise HTTPException(403,'invalid_device_signature') from None
        db.execute('DELETE FROM regional_challenges WHERE nonce=?',(proof.nonce,))
        args=(user['id'],public_key)
        if claims['action']=='enroll':
            if now-row['created']>600:
                raise HTTPException(403,'recent_login_required')
            known=db.execute('SELECT 1 FROM regional_devices WHERE user_id=? AND public_key=?',args).fetchone()
            count=db.execute('SELECT count(*) FROM regional_devices WHERE user_id=?',args[:1]).fetchone()[0]
            if not known and count>=12:
                raise HTTPException(409,'catalog_device_limit')
            db.execute('INSERT OR IGNORE INTO regional_devices VALUES (?,?,?)',(*args,now))
        elif not db.execute('SELECT 1 FROM regional_devices WHERE user_id=? AND public_key=?',args).fetchone():
            raise HTTPException(403,'device_not_registered')
        if claims['action']=='revoke':
            db.execute('DELETE FROM regional_devices WHERE user_id=? AND public_key=?',args)
            for pending in db.execute('SELECT nonce,claims FROM regional_challenges WHERE user_id=?',args[:1]).fetchall():
                if json.loads(pending['claims'])['publicKey']==public_key:
                    db.execute('DELETE FROM regional_challenges WHERE nonce=?',(pending['nonce'],))
    return claims


def region_key(channel):
    region=channel.get('regionCode')
    country=channel.get('countryCode')
    primary=region if region in ('HK','MO','TW') else country
    return primary if isinstance(primary,str) and REGION.fullmatch(primary) else None


@lru_cache(maxsize=2)
def index_snapshot(directory, digest):
    path=Path(directory)/'snapshots'/f'{digest}.json.gz'
    with path.open('rb') as file:
        blob=file.read(8*1024*1024+1)
    if len(blob)>8*1024*1024 or hashlib.sha256(blob).hexdigest()!=digest:
        raise ValueError('catalog_integrity')
    import io
    with gzip.GzipFile(fileobj=io.BytesIO(blob)) as file:
        body=file.read(32*1024*1024+1)
    if len(body)>32*1024*1024:
        raise ValueError('catalog_expanded_size')
    catalog=json.loads(body)
    groups={}
    for channel in catalog['channels']:
        if region:=region_key(channel):
            groups.setdefault(region,[]).append(channel)
    return catalog['version'],{c['id']:c for c in catalog['categories']},groups


def latest():
    directory=channel_catalog.DATA/channel_catalog.DIRECTORY
    try:
        with (directory/'manifest.json').open('rb') as file:
            manifest=json.loads(file.read(32769))
        digest=manifest['sha256']
        if not HASH.fullmatch(digest):
            raise ValueError('catalog_hash')
        version,categories,groups=index_snapshot(str(directory),digest)
        if version!=manifest['version']:
            raise ValueError('catalog_version')
        return version,categories,groups
    except (OSError,ValueError,KeyError,TypeError):
        raise HTTPException(503,'regional_catalog_unavailable') from None


def regional_package(region, categories, rows):
    used=set()
    channels=[]
    for row in rows:
        used.add(row['categoryId'])
        channels.append(dict(id=row['id'],name=row['name'],categoryId=row['categoryId'],
            logo=row.get('logoUrl'),routes=[dict(id=r['id'],url=r['url']) for r in row['routes']]))
    def name(category):
        names=[]
        while category:
            node=categories[category]
            names.append(node['name'])
            category=node['parentId']
        return ' / '.join(reversed(names))
    data=dict(categories=[dict(id=k,name=name(k)) for k in sorted(used)],channels=channels)
    if len(encoded(data))>7*1024*1024 or len(used)>1000 or len(channels)>10000:
        raise HTTPException(503,'regional_catalog_size_limit')
    revision=hashlib.sha256(encoded(dict(package=data,catalogRows=rows,categories=categories))).hexdigest()
    return dict(format='bobtv-resource',schemaVersion=1,id='bobtv-region-'+region,
                name='BobTV / '+region,revision=revision,**data)


@router.post('/complete')
def complete(proof: Proof, request: Request):
    key=signing_key()
    claims=consume(request,proof)
    action=claims['action']
    payload=dict(format=NS,action=action,nonce=claims['nonce'],
                 userId=claims['userId'],**package_metadata(key))
    if action not in ('enroll','revoke'):
        version,categories,groups=latest()
        payload['catalogVersion']=version
        if action=='regions':
            payload['regions']=[dict(code=code,channelCount=len(groups[code])) for code in sorted(groups)]
        else:
            region=claims['region']
            if region not in groups:
                raise HTTPException(404,'unknown_catalog_region')
            package=regional_package(region,categories,groups[region])
            payload.update(region=region,revision=package['revision'])
            payload['unchanged']=claims['knownRevision']==package['revision']
            if not payload['unchanged']:
                payload['package']=package
                # Preserve the exact catalog identities and reviewed route metadata.
                # Categories contain no stream addresses; only this region's rows do.
                payload['catalog']=dict(schemaVersion=1,version=version,
                    categories=list(categories.values()),channels=groups[region])
    return JSONResponse(envelope(key,payload),headers=NO_CACHE)
