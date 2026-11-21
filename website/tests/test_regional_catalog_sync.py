import base64
import gzip
import hashlib
import json

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

from test_accounts import env, login
import regional_catalog_sync as sync


@pytest.fixture
def regional(env,tmp_path,monkeypatch):
    _, _, _=env
    publisher=Ed25519PrivateKey.generate()
    seed=tmp_path/'publisher.key'
    seed.write_bytes(publisher.private_bytes_raw())
    monkeypatch.setenv('BOBTV_REGIONAL_CATALOG_SIGNING_KEY',str(seed))
    catalog=tmp_path/'data'/'channel-catalog'
    (catalog/'snapshots').mkdir(parents=True)
    monkeypatch.setattr(sync.channel_catalog,'DATA',catalog.parent)
    blob=gzip.compress(json.dumps(dict(version='v1',categories=[
        dict(id='category',name='Television',parentId=None),
    ],channels=[
        dict(id='jp-tv',name='JP',categoryId='category',countryCode='JP',
             routes=[dict(id='jp-route',url='https://example.org/jp.m3u8')]),
        dict(id='hk-tv',name='HK',categoryId='category',countryCode='CN',regionCode='HK',
             routes=[dict(id='hk-route',url='https://example.org/hk.m3u8')]),
    ])).encode())
    digest=hashlib.sha256(blob).hexdigest()
    (catalog/'snapshots'/f'{digest}.json.gz').write_bytes(blob)
    (catalog/'manifest.json').write_text(json.dumps(dict(version='v1',sha256=digest)))
    app=FastAPI()
    app.include_router(sync.router)
    return TestClient(app), publisher, env


BASE='/api/v1/regional-catalog'


def opened(result,publisher):
    assert result.status_code==200, result.text
    assert result.headers['cache-control']=='private, no-store'
    data=result.json()
    payload=base64.urlsafe_b64decode(data['payload']+'==')
    publisher.public_key().verify(sync.unb64(data['signature'],64),payload)
    return payload,json.loads(payload)


def proof(client,publisher,headers,device,action,**scope):
    public=sync.b64(device.public_key().public_bytes_raw())
    r=client.post(BASE+'/challenge',headers=headers,
        json=dict(publicKey=public,action=action,**scope))
    data,claim=opened(r,publisher)
    return dict(nonce=claim['nonce'],signature=sync.b64(device.sign(data)))


def test_guest_bootstrap_contains_no_catalog_and_all_sync_requires_login(regional):
    client,publisher,_=regional
    bootstrap=client.get(BASE+'/bootstrap.bobtv').json()
    assert bootstrap['apiBase'].endswith(BASE)
    assert sync.unb64(bootstrap['publicKey'],32)==publisher.public_key().public_bytes_raw()
    assert 'package' not in bootstrap and 'regions' not in bootstrap
    public=sync.b64(Ed25519PrivateKey.generate().public_key().public_bytes_raw())
    assert client.post(BASE+'/challenge',json=dict(publicKey=public,action='regions')).status_code==401
    assert client.post(BASE+'/complete',json=dict(nonce='a'*43,signature='b'*86)).status_code==401


def test_device_revocation_invalidates_pending_proofs_without_affecting_another_device(regional):
    client,publisher,accounts_env=regional
    _,auth=login(accounts_env)
    device=Ed25519PrivateKey.generate()
    other=Ed25519PrivateKey.generate()
    for key in [device,other]:
        opened(client.post(BASE+'/complete',headers=auth,
            json=proof(client,publisher,auth,key,'enroll')),publisher)
    pending=proof(client,publisher,auth,device,'sync',region='JP')
    revoked=proof(client,publisher,auth,device,'revoke')
    _,receipt=opened(client.post(BASE+'/complete',headers=auth,json=revoked),publisher)
    assert receipt['action']=='revoke' and 'package' not in receipt
    assert client.post(BASE+'/complete',headers=auth,json=pending).status_code==403
    public=sync.b64(device.public_key().public_bytes_raw())
    assert client.post(BASE+'/challenge',headers=auth,
        json=dict(publicKey=public,action='regions')).status_code==403
    opened(client.post(BASE+'/complete',headers=auth,
        json=proof(client,publisher,auth,other,'regions')),publisher)


def test_enrollment_signature_replay_isolation_and_revision(regional):
    client,publisher,accounts_env=regional
    _, auth=login(accounts_env)
    _, other=login(accounts_env,'other@example.org')
    device=Ed25519PrivateKey.generate()
    public=sync.b64(device.public_key().public_bytes_raw())
    assert client.post(BASE+'/challenge',headers=auth,json=dict(publicKey=public,action='regions')).status_code==403
    signed=proof(client,publisher,auth,device,'enroll')
    assert client.post(BASE+'/complete',headers=other,json=signed).status_code==403
    wrong=sync.b64(Ed25519PrivateKey.generate().sign(b'wrong'))
    assert client.post(BASE+'/complete',headers=auth,json={**signed,'signature':wrong}).status_code==403
    opened(client.post(BASE+'/complete',headers=auth,json=signed),publisher)
    assert client.post(BASE+'/complete',headers=auth,json=signed).status_code==403
    signed=proof(client,publisher,auth,device,'regions')
    _, listed=opened(client.post(BASE+'/complete',headers=auth,json=signed),publisher)
    assert listed['regions']==[dict(code='HK',channelCount=1),dict(code='JP',channelCount=1)]
    assert 'package' not in listed
    signed=proof(client,publisher,auth,device,'sync',region='JP')
    _, received=opened(client.post(BASE+'/complete',headers=auth,json=signed),publisher)
    assert [row['id'] for row in received['package']['channels']]==['jp-tv']
    signed=proof(client,publisher,auth,device,'sync',region='JP',knownRevision=received['revision'])
    _, next_poll=opened(client.post(BASE+'/complete',headers=auth,json=signed),publisher)
    assert next_poll['unchanged'] and 'package' not in next_poll
    signed=proof(client,publisher,auth,device,'sync',region='HK')
    assert accounts_env[0].post('/api/v1/account/logout',headers=auth).status_code==200
    assert client.post(BASE+'/complete',headers=auth,json=signed).status_code==401
