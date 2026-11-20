import base64
import hashlib
import json
import sys
import time
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import accounts as a


@pytest.fixture
def env(tmp_path, monkeypatch):
    path = tmp_path / 'config.json'
    path.write_text(json.dumps({'secret': 's' * 64, 'smtp_password': 'test-only',
                               'google_client_id': 'client', 'google_client_secret': 'secret'}))
    monkeypatch.setenv('BOBTV_ACCOUNTS_CONFIG', str(path))
    monkeypatch.setenv('BOBTV_DATA_DIR', str(tmp_path / 'data'))
    sent = []
    monkeypatch.setattr(a, 'send_code', lambda email, code: sent.append((email, code)))
    app = FastAPI()
    app.include_router(a.router)
    client = TestClient(app, base_url=a.origin())
    return client, sent, path


def login(env, email='person@example.com'):
    c, sent, _ = env
    assert c.post('/api/v1/account/email/code', json={'email': email}).status_code == 200
    r = c.post('/api/v1/account/email/verify', json={'email': email, 'code': sent[-1][1]})
    assert r.status_code == 200, r.text
    return r.json(), {'Authorization': 'Bearer ' + r.json()['token']}


def test_optional_no_secrets_or_implicit_admin(env):
    c, _, _ = env
    assert c.get('/api/v1/account/config').json() == {'email': True, 'google': True, 'apple': False, 'optional': True}
    assert c.get('/api/v1/account/me').status_code == 401
    assert c.get('/api/v1/admin/users').status_code == 401
    r = c.get('/admin')
    assert r.status_code == 200 and 'noindex' in r.headers['x-robots-tag']
    assert 'frame-ancestors' in r.headers['content-security-policy']


def test_email_single_use_hash_logout(env):
    c, sent, _ = env
    value, headers = login(env)
    assert value['user']['verified'] is True and not value['user']['admin']
    assert c.get('/api/v1/account/me', headers=headers).status_code == 200
    assert c.get('/api/v1/admin/users', headers=headers).status_code == 403
    assert c.post('/api/v1/account/email/verify', json={'email': sent[-1][0], 'code': sent[-1][1]}).status_code == 400
    with a.database() as db:
        assert db.execute('SELECT token_hash FROM sessions').fetchone()[0] != value['token']
    assert c.post('/api/v1/account/logout', headers=headers).status_code == 200
    assert c.get('/api/v1/account/me', headers=headers).status_code == 401


def test_failed_code_attempts_are_persisted_and_limited(env):
    c, sent, _ = env
    c.post('/api/v1/account/email/code', json={'email': 'p@example.com'})
    right = sent[-1][1]
    wrong = '000000' if right != '000000' else '111111'
    with a.database() as db:
        assert db.execute('SELECT hash FROM codes').fetchone()[0] != right
    for _ in range(5):
        assert c.post('/api/v1/account/email/verify', json={'email': 'p@example.com', 'code': wrong}).status_code == 400
    assert c.post('/api/v1/account/email/verify', json={'email': 'p@example.com', 'code': right}).status_code == 400


def test_expiry_send_throttle_and_failed_delivery(env, monkeypatch):
    c, sent, _ = env
    c.post('/api/v1/account/email/code', json={'email': 'p@example.com'})
    assert c.post('/api/v1/account/email/code', json={'email': 'p@example.com'}).status_code == 429
    with a.database() as db:
        db.execute('UPDATE codes SET expires=0')
    assert c.post('/api/v1/account/email/verify', json={'email': 'p@example.com', 'code': sent[-1][1]}).status_code == 400
    def fail(*args):
        raise a.HTTPException(503, 'email_delivery_failed')
    monkeypatch.setattr(a, 'send_code', fail)
    assert c.post('/api/v1/account/email/code', json={'email': 'new@example.com'}).status_code == 503
    with a.database() as db:
        assert not db.execute('SELECT * FROM codes WHERE email=?', ('new@example.com',)).fetchone()


def test_admin_crud_disable_and_verified_cannot_self_elevate(env):
    c, _, _ = env
    admin, h = login(env, 'sunsx@outlook.com')
    assert admin['user']['admin']
    r = c.post('/api/v1/admin/users', headers=h, json={'email': 'member@example.com', 'name': '<script>', 'verified': False})
    assert r.status_code == 200
    uid = r.json()['id']
    assert not r.json()['verified']
    value, mh = login(env, 'member@example.com')
    assert c.patch('/api/v1/admin/users/'+uid, headers=mh, json={'email': 'sunshaoxuan@gmail.com', 'verified': True}).status_code == 403
    assert c.patch('/api/v1/admin/users/'+uid, headers=h, json={'email': 'member@example.com', 'verified': True, 'disabled': True}).status_code == 200
    assert c.get('/api/v1/account/me', headers=mh).status_code == 401
    assert c.patch('/api/v1/admin/users/'+admin['user']['id'], headers=h, json={'email': 'sunsx@outlook.com', 'disabled': True}).status_code == 409
    assert c.post('/api/v1/admin/users', headers=h, json={'email': 'member@example.com'}).status_code == 409
    assert c.get('/api/v1/admin/users?q=member', headers=h).json()['users'][0]['disabled']
    with a.database() as db:
        assert db.execute('SELECT count(*) FROM account_audit').fetchone()[0] == 2


def test_cookie_secure_and_csrf(env):
    c, sent, _ = env
    c.post('/api/v1/account/email/code', json={'email': 'sunsx@outlook.com'})
    r = c.post('/api/v1/account/email/verify', headers={'Origin': a.origin()}, json={'email': 'sunsx@outlook.com', 'code': sent[-1][1]})
    cookie = r.headers['set-cookie']
    assert 'HttpOnly' in cookie and 'Secure' in cookie and 'SameSite=lax' in cookie
    assert c.get('/api/v1/admin/users').status_code == 200
    assert c.post('/api/v1/admin/users', json={'email': 'new@example.com'}).status_code == 403
    assert c.post('/api/v1/admin/users', headers={'Origin': 'https://evil.example'}, json={'email': 'new@example.com'}).status_code == 403
    assert c.post('/api/v1/admin/users', headers={'Origin': a.origin()}, json={'email': 'new@example.com'}).status_code == 200


def test_delete_cascades_and_requires_fresh_login(env):
    c, _, _ = env
    value, h = login(env)
    with a.database() as db:
        db.execute('UPDATE sessions SET created=?', (int(time.time()) - 601,))
    assert c.delete('/api/v1/account/me', headers=h).status_code == 403
    with a.database() as db:
        db.execute('UPDATE sessions SET created=?', (int(time.time()),))
        db.execute('INSERT INTO identities VALUES (?,?,?,NULL)', ('google', 'subject', value['user']['id']))
    assert c.delete('/api/v1/account/me', headers=h).status_code == 200
    assert c.get('/api/v1/account/me', headers=h).status_code == 401
    with a.database() as db:
        assert db.execute('SELECT count(*) FROM identities').fetchone()[0] == 0
        assert db.execute('SELECT count(*) FROM users').fetchone()[0] == 0


def ticket(env):
    proof = 'v' * 43
    challenge = base64.urlsafe_b64encode(hashlib.sha256(proof.encode()).digest()).decode().rstrip('=')
    r = env[0].post('/api/v1/account/oauth/start', json={'provider': 'google', 'proof': challenge})
    assert r.status_code == 200
    return r.json()['ticket'], proof, r.json()['url']


def test_oauth_proof_and_single_use(env):
    c, _, _ = env
    uid = login(env)[0]['user']['id']
    tid, proof, url = ticket(env)
    assert 'code_challenge_method=S256' in url and 'nonce=' in url
    assert c.post('/api/v1/account/oauth/poll', json={'ticket': tid, 'proof': 'x' * 43}).status_code == 400
    assert c.post('/api/v1/account/oauth/poll', json={'ticket': tid, 'proof': proof}).json() == {'pending': True}
    with a.database() as db:
        db.execute("UPDATE oauth SET status='ready',user_id=? WHERE id=?", (uid, tid))
    assert c.post('/api/v1/account/oauth/poll', json={'ticket': tid, 'proof': proof}, headers={'Origin': a.origin()}).status_code == 200
    assert c.post('/api/v1/account/oauth/poll', json={'ticket': tid, 'proof': proof}).status_code == 400


def test_oauth_callback_rejects_replay_and_bad_signed_token(env, monkeypatch):
    c, _, _ = env
    tid, _, _ = ticket(env)
    with a.database() as db:
        state = db.execute('SELECT state FROM oauth WHERE id=?', (tid,)).fetchone()[0]
    monkeypatch.setattr(a, 'post_provider', lambda *args: {'id_token': 'not-a-signed-token'})
    assert c.get('/api/v1/account/oauth/google/callback', params={'state': state, 'code': 'code'}).status_code == 400
    assert c.get('/api/v1/account/oauth/google/callback', params={'state': state, 'code': 'code'}).status_code == 400
    with a.database() as db:
        assert db.execute('SELECT count(*) FROM users').fetchone()[0] == 0


def test_configuration_fails_closed(env):
    c, _, path = env
    path.write_text('{}')
    assert not c.get('/api/v1/account/config').json()['email']
    assert c.post('/api/v1/account/email/code', json={'email': 'p@example.com'}).status_code == 503
    assert c.post('/api/v1/account/oauth/start', json={'provider': 'apple', 'proof': 'v' * 43}).status_code == 503


@pytest.mark.parametrize('bad', [None, 'nonce', 'audience', 'expired', 'signature', 'external_email'])
def test_real_signed_oidc_validation(env, monkeypatch, bad):
    from cryptography.hazmat.primitives.asymmetric import rsa
    from types import SimpleNamespace
    c, _, _ = env
    tid, proof, _ = ticket(env)
    with a.database() as db:
        row = db.execute('SELECT * FROM oauth WHERE id=?', (tid,)).fetchone()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = int(time.time())
    claims = {'iss': 'https://accounts.google.com', 'aud': 'client', 'sub': 'google-subject',
              'iat': now, 'exp': now + 300, 'nonce': row['nonce'],
              'email': 'person@gmail.com', 'email_verified': True, 'name': 'User'}
    if bad == 'nonce': claims['nonce'] = 'incorrect'
    if bad == 'audience': claims['aud'] = 'attacker-client'
    if bad == 'expired': claims['exp'] = now - 100
    if bad == 'external_email': claims['email'] = 'sunsx@outlook.com'
    encoded = a.jwt.encode(claims, other if bad == 'signature' else key, algorithm='RS256')
    monkeypatch.setattr(a, 'post_provider', lambda *args: {'id_token': encoded})
    monkeypatch.setattr(a.jwt, 'PyJWKClient', lambda *args, **kw: SimpleNamespace(get_signing_key_from_jwt=lambda token: SimpleNamespace(key=key.public_key())))
    r = c.get('/api/v1/account/oauth/google/callback', params={'state': row['state'], 'code': 'exchanged-code'})
    assert r.status_code == (400 if bad else 200)
    result = c.post('/api/v1/account/oauth/poll', json={'ticket': tid, 'proof': proof})
    assert result.status_code == (400 if bad else 200)
    with a.database() as db:
        assert db.execute('SELECT count(*) FROM users').fetchone()[0] == (0 if bad else 1)


def test_apple_refresh_encrypted_and_revoke_failure_preserves_account(env, monkeypatch):
    c, _, path = env
    uid, headers = login(env)[0:2]
    uid = uid['user']['id']
    with a.database() as db:
        encrypted = a.cipher().encrypt(b'refresh-secret').decode()
        assert 'refresh-secret' not in encrypted
        db.execute('INSERT INTO identities VALUES (?,?,?,?)', ('apple', 'apple-sub', uid, encrypted))
    monkeypatch.setattr(a, 'apple_secret', lambda c: 'signed-secret')
    values = json.loads(path.read_text()); values['apple_client_id'] = 'client'; path.write_text(json.dumps(values))
    def failed(*args): raise OSError('provider unavailable')
    monkeypatch.setattr(a, 'post_provider', failed)
    assert c.delete('/api/v1/account/me', headers=headers).status_code == 503
    assert c.get('/api/v1/account/me', headers=headers).status_code == 200
    calls = []
    monkeypatch.setattr(a, 'post_provider', lambda url, data: calls.append((url, data)) or {})
    assert c.delete('/api/v1/account/me', headers=headers).status_code == 200
    assert calls[0][0] == 'https://appleid.apple.com/auth/revoke'
    assert calls[0][1]['token'] == 'refresh-secret'
