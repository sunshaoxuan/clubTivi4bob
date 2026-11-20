"""Optional BobTV identity service. Opaque sessions, verified email and OIDC.

No player/content data is required. Configuration is read from a root-managed
JSON file; passwords, codes and provider tokens are never returned or logged.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import time
from contextlib import contextmanager
from email.message import EmailMessage
from pathlib import Path
from urllib.parse import parse_qs, urlencode
from urllib.request import Request as UrlRequest, urlopen

import jwt
from cryptography.fernet import Fernet
from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

router = APIRouter()
ADMINS = frozenset({'sunsx@outlook.com', 'sunshaoxuan@gmail.com'})
BASE = Path(__file__).resolve().parent
SESSION_SECONDS = 30 * 86400


def config():
    path = Path(os.environ.get('BOBTV_ACCOUNTS_CONFIG', '/etc/bobtv/accounts.json'))
    return json.loads(path.read_text()) if path.is_file() else {}


def origin():
    return config().get('origin', 'https://bobtv.briconbric.com').rstrip('/')


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def pepper():
    value = config().get('secret', '')
    if len(value) < 32:
        raise HTTPException(503, 'account_service_unconfigured')
    return value.encode()


def code_hash(email, code):
    return hmac.new(pepper(), (email + ':' + code).encode(), hashlib.sha256).hexdigest()


def cipher():
    return Fernet(base64.urlsafe_b64encode(hashlib.sha256(pepper()).digest()))


@contextmanager
def database():
    directory = Path(os.environ.get('BOBTV_DATA_DIR', BASE / 'data'))
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'accounts.sqlite3'
    conn = sqlite3.connect(path, timeout=10)
    os.chmod(path, 0o600)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    conn.executescript('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, name TEXT NOT NULL,
        verified INTEGER NOT NULL DEFAULT 0, disabled INTEGER NOT NULL DEFAULT 0,
        created INTEGER NOT NULL, updated INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS identities (
        provider TEXT NOT NULL, subject TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        refresh TEXT, PRIMARY KEY(provider, subject));
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created INTEGER NOT NULL, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS codes (
        email TEXT PRIMARY KEY, hash TEXT NOT NULL, expires INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS limits (key TEXT PRIMARY KEY, count INTEGER NOT NULL, expires INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS oauth (
        id TEXT PRIMARY KEY, proof TEXT NOT NULL, provider TEXT NOT NULL, state TEXT UNIQUE NOT NULL,
        nonce TEXT NOT NULL, verifier TEXT NOT NULL, expires INTEGER NOT NULL,
        user_id TEXT REFERENCES users(id) ON DELETE CASCADE, status TEXT NOT NULL DEFAULT 'pending');
      CREATE TABLE IF NOT EXISTS account_audit (
        id INTEGER PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, created INTEGER NOT NULL);
    ''')
    conn.execute('DELETE FROM account_audit WHERE created < ?', (int(time.time()) - 180 * 86400,))
    conn.commit()
    try:
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


def clean_email(value):
    value = value.strip().lower()
    if len(value) > 254 or not re.fullmatch(r'[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+', value):
        raise HTTPException(422, 'invalid_email')
    return value


def public_user(row):
    return dict(id=row['id'], email=row['email'], name=row['name'],
                verified=bool(row['verified']), disabled=bool(row['disabled']),
                admin=row['email'] in ADMINS and bool(row['verified']), created=row['created'])


def throttle(key, maximum, seconds):
    now = int(time.time())
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        db.execute('DELETE FROM limits WHERE expires < ?', (now,))
        db.execute('INSERT INTO limits VALUES (?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1', (key, now + seconds))
        count = db.execute('SELECT count FROM limits WHERE key=?', (key,)).fetchone()[0]
    if count > maximum:
        raise HTTPException(429, 'rate_limited', headers={'Retry-After': str(seconds)})


def client_key(request):
    # The ASGI proxy is configured to trust loopback only, not arbitrary XFF.
    return digest(request.client.host if request.client else 'unknown')


def csrf(request):
    if request.headers.get('origin') != origin():
        raise HTTPException(403, 'invalid_origin')


def current(request, admin=False):
    authorization = request.headers.get('authorization', '')
    bearer = authorization.startswith('Bearer ')
    if authorization and not bearer:
        raise HTTPException(401, 'login_required')
    token = authorization[7:] if bearer else request.cookies.get('bobtv_session', '')
    if not bearer and request.method not in ('GET', 'HEAD'):
        csrf(request)
    with database() as db:
        row = db.execute('SELECT users.*, sessions.created AS authenticated_at FROM sessions JOIN users ON users.id=sessions.user_id WHERE token_hash=? AND expires>?',
                         (digest(token), int(time.time()))).fetchone()
    if not row or row['disabled']:
        raise HTTPException(401, 'login_required')
    if admin and not (row['verified'] and row['email'] in ADMINS):
        raise HTTPException(403, 'admin_required')
    return row


def issue_session(db, user_id):
    row = db.execute('SELECT * FROM users WHERE id=?', (user_id,)).fetchone()
    if row['disabled']:
        raise HTTPException(403, 'account_disabled')
    now = int(time.time())
    db.execute('DELETE FROM sessions WHERE expires < ?', (now,))
    token = secrets.token_urlsafe(48)
    db.execute('INSERT INTO sessions VALUES (?,?,?,?)', (digest(token), user_id, now, now + SESSION_SECONDS))
    return {'token': token, 'expiresAt': now + SESSION_SECONDS, 'user': public_user(row)}


def cookie(response, token):
    response.set_cookie('bobtv_session', token, max_age=SESSION_SECONDS, secure=True,
                        httponly=True, samesite='lax', path='/')


class EmailInput(BaseModel):
    email: str = Field(max_length=254)


class CodeInput(EmailInput):
    code: str = Field(min_length=6, max_length=6, pattern=r'^\d{6}$')


class UserInput(EmailInput):
    name: str = Field(default='', max_length=100)
    verified: bool = False
    disabled: bool = False


class OAuthInput(BaseModel):
    provider: str = Field(pattern='^(google|apple)$')
    proof: str = Field(min_length=43, max_length=128, pattern=r'^[A-Za-z0-9_-]+$')


class TicketInput(BaseModel):
    ticket: str = Field(max_length=128)
    proof: str = Field(min_length=43, max_length=128)


@router.get('/api/v1/account/config')
def account_config(response: Response):
    c = config()
    response.headers['Cache-Control'] = 'no-store'
    return {'email': bool(c.get('smtp_password') and c.get('secret')),
            'google': bool(c.get('google_client_id') and c.get('google_client_secret') and c.get('secret')),
            'apple': bool(c.get('apple_client_id') and c.get('apple_team_id') and c.get('apple_key_id') and c.get('apple_private_key') and c.get('secret')),
            'optional': True}


def send_code(email, code):
    c = config()
    if not c.get('smtp_password'):
        raise HTTPException(503, 'email_unconfigured')
    message = EmailMessage()
    message['From'] = c.get('smtp_from', 'postmaster@bobuy.cc')
    message['To'] = email
    message['Subject'] = 'BobTV verification code / 验证码'
    message.set_content(f'BobTV\n\n验证码 / Verification code: {code}\n\n10 分钟内有效。请勿向他人透露验证码。\nValid for 10 minutes. Do not share this code.\nIf you did not request this, ignore this email.')
    try:
        # Implicit TLS only. No plaintext fallback and normal certificate checks.
        with smtplib.SMTP_SSL(c.get('smtp_host', 'mail.briconbric.com'), int(c.get('smtp_port', 465)),
                              timeout=15, context=ssl.create_default_context()) as smtp:
            smtp.login(c.get('smtp_user', 'postmaster@bobuy.cc'), c['smtp_password'])
            smtp.send_message(message)
    except (OSError, smtplib.SMTPException):
        raise HTTPException(503, 'email_delivery_failed') from None


@router.post('/api/v1/account/email/code')
def request_code(body: EmailInput, request: Request):
    email = clean_email(body.email)
    throttle('send-global', 120, 3600)
    throttle('send-ip:' + client_key(request), 15, 3600)
    throttle('send-minute:' + digest(email), 1, 60)
    throttle('send-hour:' + digest(email), 5, 3600)
    code = f'{secrets.randbelow(1000000):06d}'
    # Hold a write transaction through delivery so concurrent resends cannot
    # deliver a code that was already superseded by another pending request.
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        db.execute('DELETE FROM codes WHERE expires < ?', (int(time.time()),))
        db.execute('INSERT OR REPLACE INTO codes VALUES (?,?,?,0)', (email, code_hash(email, code), int(time.time()) + 600))
        send_code(email, code)
    return {'sent': True, 'retryAfter': 60}


@router.post('/api/v1/account/email/verify')
def verify_code(body: CodeInput, request: Request, response: Response):
    email = clean_email(body.email)
    throttle('verify:' + client_key(request), 30, 600)
    valid = False
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT * FROM codes WHERE email=?', (email,)).fetchone()
        if row and row['expires'] > time.time() and row['attempts'] < 5:
            valid = hmac.compare_digest(row['hash'], code_hash(email, body.code))
            db.execute('UPDATE codes SET attempts=attempts+1 WHERE email=?', (email,))
            if valid:
                db.execute('DELETE FROM codes WHERE email=?', (email,))
        # Failed-attempt counters must commit even when returning an error.
    if not valid:
        raise HTTPException(400, 'invalid_or_expired_code')
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        row = db.execute('SELECT * FROM users WHERE email=?', (email,)).fetchone()
        now = int(time.time())
        uid = row['id'] if row else secrets.token_hex(16)
        if row:
            db.execute('UPDATE users SET verified=1,updated=? WHERE id=?', (now, uid))
        else:
            db.execute('INSERT INTO users VALUES (?,?,?,1,0,?,?)', (uid, email, '', now, now))
        result = issue_session(db, uid)
    response.headers['Cache-Control'] = 'no-store'
    # Cookies are set only for same-origin browser requests. Apps use bearer.
    if request.headers.get('origin') == origin():
        cookie(response, result['token'])
    return result


@router.get('/api/v1/account/me')
def me(request: Request, response: Response):
    response.headers['Cache-Control'] = 'no-store'
    return public_user(current(request))


@router.post('/api/v1/account/logout')
def logout(request: Request, response: Response):
    current(request)
    token = request.headers.get('authorization', '')[7:] if request.headers.get('authorization', '').startswith('Bearer ') else request.cookies.get('bobtv_session', '')
    with database() as db:
        db.execute('DELETE FROM sessions WHERE token_hash=?', (digest(token),))
    response.delete_cookie('bobtv_session', path='/', secure=True, httponly=True, samesite='lax')
    return {'ok': True}


def apple_secret(c):
    now = int(time.time())
    return jwt.encode({'iss': c['apple_team_id'], 'iat': now, 'exp': now + 300,
                       'aud': 'https://appleid.apple.com', 'sub': c['apple_client_id']},
                      c['apple_private_key'], algorithm='ES256', headers={'kid': c['apple_key_id']})


def post_provider(url, fields):
    request = UrlRequest(url, data=urlencode(fields).encode(), headers={'Accept': 'application/json'})
    with urlopen(request, timeout=15) as response:
        raw = response.read()
        return json.loads(raw) if raw else {}


@router.delete('/api/v1/account/me')
def delete_account(request: Request, response: Response):
    user = current(request)
    # Destructive identity changes require a newly authenticated session.
    if time.time() - user['authenticated_at'] > 600:
        raise HTTPException(403, 'recent_login_required')
    with database() as db:
        apple = db.execute("SELECT refresh FROM identities WHERE user_id=? AND provider='apple'", (user['id'],)).fetchall()
    for row in apple:
        if row['refresh']:
            try:
                c = config()
                post_provider('https://appleid.apple.com/auth/revoke', {
                    'client_id': c['apple_client_id'], 'client_secret': apple_secret(c),
                    'token': cipher().decrypt(row['refresh'].encode()).decode(), 'token_type_hint': 'refresh_token'})
            except Exception:
                raise HTTPException(503, 'apple_revocation_failed') from None
    with database() as db:
        db.execute('DELETE FROM codes WHERE email=?', (user['email'],))
        db.execute('DELETE FROM users WHERE id=?', (user['id'],))
    response.delete_cookie('bobtv_session', path='/', secure=True, httponly=True, samesite='lax')
    return {'deleted': True}


@router.post('/api/v1/account/oauth/start')
def oauth_start(body: OAuthInput, request: Request):
    throttle('oauth:' + client_key(request), 30, 600)
    c = config()
    if not account_config(Response()).get(body.provider):
        raise HTTPException(503, 'provider_unconfigured')
    ticket, state, nonce, verifier = [secrets.token_urlsafe(32) for _ in range(4)]
    with database() as db:
        db.execute('DELETE FROM oauth WHERE expires < ?', (int(time.time()),))
        db.execute('INSERT INTO oauth (id,proof,provider,state,nonce,verifier,expires) VALUES (?,?,?,?,?,?,?)',
                   (ticket, body.proof, body.provider, state, nonce, verifier, int(time.time()) + 300))
    params = {'client_id': c[body.provider + '_client_id'], 'redirect_uri': origin() + '/api/v1/account/oauth/' + body.provider + '/callback',
              'response_type': 'code', 'scope': 'openid email profile' if body.provider == 'google' else 'name email', 'state': state, 'nonce': nonce}
    if body.provider == 'google':
        params.update(code_challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('='), code_challenge_method='S256')
        endpoint = 'https://accounts.google.com/o/oauth2/v2/auth'
    else:
        params['response_mode'] = 'form_post'
        endpoint = 'https://appleid.apple.com/auth/authorize'
    return JSONResponse({'ticket': ticket, 'url': endpoint + '?' + urlencode(params)}, headers={'Cache-Control': 'no-store'})


def finish_oauth(provider, fields):
    state = fields.get('state', '')
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        flow = db.execute('SELECT * FROM oauth WHERE state=? AND provider=? AND expires>? AND status=?', (state, provider, int(time.time()), 'pending')).fetchone()
        if not flow:
            raise HTTPException(400, 'invalid_oauth_state')
        db.execute("UPDATE oauth SET status='exchanging' WHERE id=?", (flow['id'],))
    try:
        if fields.get('error') or not fields.get('code'):
            raise ValueError('cancelled')
        c = config()
        form = {'code': fields['code'], 'grant_type': 'authorization_code', 'client_id': c[provider + '_client_id'],
                'client_secret': c['google_client_secret'] if provider == 'google' else apple_secret(c),
                'redirect_uri': origin() + '/api/v1/account/oauth/' + provider + '/callback'}
        if provider == 'google':
            form['code_verifier'] = flow['verifier']
        tokens = post_provider('https://oauth2.googleapis.com/token' if provider == 'google' else 'https://appleid.apple.com/auth/token', form)
        jwks = jwt.PyJWKClient('https://www.googleapis.com/oauth2/v3/certs' if provider == 'google' else 'https://appleid.apple.com/auth/keys', timeout=10)
        key = jwks.get_signing_key_from_jwt(tokens['id_token']).key
        claims = jwt.decode(tokens['id_token'], key, algorithms=['RS256'], audience=c[provider + '_client_id'],
                            issuer=['https://accounts.google.com', 'accounts.google.com'] if provider == 'google' else 'https://appleid.apple.com',
                            options={'require': ['exp', 'iat', 'sub', 'iss', 'aud', 'nonce']})
        if not hmac.compare_digest(claims['nonce'], flow['nonce']):
            raise ValueError('nonce')
        if claims.get('email_verified') not in (True, 'true'):
            raise ValueError('unverified')
        email = clean_email(claims['email'])
        # External Google emails can be stale even when email_verified is true.
        # Those users can prove current mailbox ownership with the email flow.
        if provider == 'google' and not (email.endswith('@gmail.com') or claims.get('hd')):
            raise ValueError('email_verification_required')
        with database() as db:
            db.execute('BEGIN IMMEDIATE')
            identity = db.execute('SELECT user_id FROM identities WHERE provider=? AND subject=?', (provider, claims['sub'])).fetchone()
            existing = db.execute('SELECT * FROM users WHERE email=?', (email,)).fetchone()
            if identity:
                uid = identity['user_id']
            elif existing and existing['verified']:
                uid = existing['id']
            elif existing:
                # Email ownership is now proven; the manually created record can be claimed.
                uid = existing['id']
                db.execute('UPDATE users SET verified=1,updated=? WHERE id=?', (int(time.time()), uid))
            else:
                uid = secrets.token_hex(16)
                now = int(time.time())
                db.execute('INSERT INTO users VALUES (?,?,?,1,0,?,?)', (uid, email, str(claims.get('name', ''))[:100], now, now))
            refresh = cipher().encrypt(tokens['refresh_token'].encode()).decode() if tokens.get('refresh_token') and provider == 'apple' else None
            if provider == 'apple' and not refresh and not identity:
                raise ValueError('missing_revocation_token')
            db.execute('INSERT INTO identities VALUES (?,?,?,?) ON CONFLICT(provider,subject) DO UPDATE SET refresh=COALESCE(excluded.refresh,identities.refresh)', (provider, claims['sub'], uid, refresh))
            user = db.execute('SELECT disabled FROM users WHERE id=?', (uid,)).fetchone()
            if user['disabled']:
                raise ValueError('disabled')
            db.execute("UPDATE oauth SET user_id=?,status='ready' WHERE id=?", (uid, flow['id']))
    except Exception:
        with database() as db:
            db.execute("UPDATE oauth SET status='failed' WHERE id=?", (flow['id'],))
        return HTMLResponse('<meta name="viewport" content="width=device-width"><p>登录未完成，请返回 BobTV 重试。 / Sign-in failed. Return to BobTV and try again.</p>', status_code=400, headers={'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer'})
    return HTMLResponse('<meta name="viewport" content="width=device-width"><p>登录成功，请返回 BobTV。 / Signed in. Return to BobTV.</p>', headers={'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer'})


@router.get('/api/v1/account/oauth/google/callback')
def google_callback(request: Request):
    return finish_oauth('google', dict(request.query_params))


@router.post('/api/v1/account/oauth/apple/callback')
async def apple_callback(request: Request):
    raw = bytearray()
    async for chunk in request.stream():
        raw.extend(chunk)
        if len(raw) > 16384:
            raise HTTPException(413)
    fields = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
    from starlette.concurrency import run_in_threadpool
    return await run_in_threadpool(finish_oauth, 'apple', fields)


@router.post('/api/v1/account/oauth/poll')
def oauth_poll(body: TicketInput, request: Request):
    throttle('poll:' + client_key(request), 300, 600)
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        flow = db.execute('SELECT * FROM oauth WHERE id=? AND expires>?', (body.ticket, int(time.time()))).fetchone()
        proof = base64.urlsafe_b64encode(hashlib.sha256(body.proof.encode()).digest()).decode().rstrip('=')
        if not flow or not hmac.compare_digest(flow['proof'], proof):
            raise HTTPException(400, 'invalid_ticket')
        if flow['status'] == 'failed':
            raise HTTPException(400, 'provider_login_failed')
        if flow['status'] != 'ready':
            return {'pending': True}
        result = issue_session(db, flow['user_id'])
        db.execute('DELETE FROM oauth WHERE id=?', (body.ticket,))
        response = JSONResponse(result, headers={'Cache-Control': 'no-store'})
        if request.headers.get('origin') == origin():
            cookie(response, result['token'])
        return response


@router.get('/admin')
def admin_page():
    return FileResponse(BASE / 'account_admin.html', headers={'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex, nofollow',
                        'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
                        'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer'})


@router.get('/admin/accounts.js')
def admin_script():
    return FileResponse(BASE / 'account_admin.js', media_type='text/javascript', headers={'Cache-Control': 'no-store'})


@router.get('/admin/accounts.css')
def admin_style():
    return FileResponse(BASE / 'account_admin.css', media_type='text/css')


@router.get('/api/v1/admin/users')
def list_users(request: Request, response: Response, q: str = '', offset: int = 0):
    current(request, admin=True)
    response.headers['Cache-Control'] = 'no-store'
    if len(q) > 100 or offset < 0 or offset > 1000000:
        raise HTTPException(422)
    with database() as db:
        rows = db.execute('SELECT * FROM users WHERE instr(email,?)>0 OR instr(name,?)>0 ORDER BY created DESC,id LIMIT 51 OFFSET ?', (q.lower(), q, offset)).fetchall()
    return {'users': [public_user(row) for row in rows[:50]], 'hasMore': len(rows) > 50}


def audit(db, actor, action, target):
    db.execute('INSERT INTO account_audit(actor,action,target,created) VALUES (?,?,?,?)', (actor, action, target, int(time.time())))


@router.post('/api/v1/admin/users')
def create_user(body: UserInput, request: Request):
    actor = current(request, admin=True)
    email = clean_email(body.email)
    uid, now = secrets.token_hex(16), int(time.time())
    try:
        with database() as db:
            db.execute('INSERT INTO users VALUES (?,?,?,?,?,?,?)', (uid, email, body.name.strip(), int(body.verified), int(body.disabled), now, now))
            audit(db, actor['id'], 'create', uid)
            return public_user(db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone())
    except sqlite3.IntegrityError:
        raise HTTPException(409, 'email_exists') from None


@router.patch('/api/v1/admin/users/{uid}')
def update_user(uid: str, body: UserInput, request: Request):
    actor = current(request, admin=True)
    email = clean_email(body.email)
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        old = db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone()
        if not old:
            raise HTTPException(404, 'user_not_found')
        if uid == actor['id'] and (body.disabled or not body.verified or email not in ADMINS):
            raise HTTPException(409, 'cannot_remove_own_admin_access')
        # Provider subjects stay bound to their verified identity. Email changes
        # would otherwise let a provider session inherit a different admin email.
        if email != old['email'] and db.execute('SELECT 1 FROM identities WHERE user_id=?', (uid,)).fetchone():
            raise HTTPException(409, 'provider_email_immutable')
        try:
            db.execute('UPDATE users SET email=?,name=?,verified=?,disabled=?,updated=? WHERE id=?',
                       (email, body.name.strip(), int(body.verified), int(body.disabled), int(time.time()), uid))
        except sqlite3.IntegrityError:
            raise HTTPException(409, 'email_exists') from None
        if body.disabled or email != old['email'] or body.verified != bool(old['verified']):
            db.execute('DELETE FROM sessions WHERE user_id=?', (uid,))
            db.execute('DELETE FROM oauth WHERE user_id=?', (uid,))
        audit(db, actor['id'], 'update', uid)
        return public_user(db.execute('SELECT * FROM users WHERE id=?', (uid,)).fetchone())
