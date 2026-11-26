"""Native Mac HAP authentication for transient, PIN and receiver-password modes.

All server proofs and identities must pass verification before control-channel
encryption is enabled. Apple-account authentication is outside this transport.
Authentication completion does not establish physical playback acceptance.
"""
import asyncio
import binascii
import hashlib
import hmac

from srptools import SRPClientSession, SRPContext, constants
from srptools.exceptions import SRPException
from pyatv.auth.hap_pairing import PairVerifyProcedure
from pyatv.auth.hap_session import HAPSession
from pyatv.auth.hap_srp import hkdf_expand
from pyatv.auth.hap_tlv8 import TlvValue, write_tlv
from pyatv.exceptions import AuthenticationError
from pyatv.auth.hap_srp import SRPAuthHandler
from pyatv.auth.hap_pairing import HapCredentials, parse_credentials
from pyatv.protocols.airplay.auth.hap import AirPlayHapPairVerifyProcedure
from pyatv.support import chacha20
from pyatv.auth.hap_tlv8 import read_tlv
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature, InvalidTag
from cast_diagnostics import record


class MacAuthenticationError(Exception):
    """Safe diagnostic containing no response bodies, keys or source URLs."""

    def __init__(self, stage, reason, *, http_status=None, tlv_error=None,
                 retry_after=None, mode=None):
        self.stage = stage
        self.reason = reason
        self.http_status = http_status
        self.tlv_error = tlv_error
        self.retry_after = retry_after
        self.auth_mode = mode
        super().__init__(f'{stage}: {reason}')


def decode_pairing_response(body, state):
    """Validate TLV boundaries and state before consuming cryptographic fields."""
    stage = f'M{state}'
    if not isinstance(body, bytes) or len(body) > 8192:
        raise MacAuthenticationError(stage, 'invalid-response')
    fields = {}
    offset = 0
    while offset < len(body):
        if offset + 2 > len(body):
            raise MacAuthenticationError(stage, 'truncated-tlv')
        tag, size = body[offset:offset + 2]
        offset += 2
        if offset + size > len(body):
            raise MacAuthenticationError(stage, 'truncated-tlv')
        fields[tag] = fields.get(tag, b'') + body[offset:offset + size]
        offset += size
    if TlvValue.Error in fields:
        # Preserve a bounded protocol code, never arbitrary receiver text.
        value = fields[TlvValue.Error]
        code = value[0] if len(value) == 1 else 'invalid'
        retry = fields.get(TlvValue.BackOff, b'')
        raise MacAuthenticationError(stage, f'receiver-error-{code}',
            tlv_error=code if isinstance(code, int) else None,
            retry_after=int.from_bytes(retry, 'little') if 0 < len(retry) <= 4 else None)
    if fields.get(TlvValue.SeqNo) != bytes([state]):
        raise MacAuthenticationError(stage, 'unexpected-state')
    return fields


class MacTransientVerifier(PairVerifyProcedure):
    """One ephemeral SRP exchange without requesting an on-screen PIN.

    3939 is the protocol's transient-pairing value, not a user PIN. Only use
    this on receivers configured to permit transient access. Verify the remote
    SRP proof before enabling either encrypted control or event channels.
    """

    def __init__(self, connection, secret='3939', mode='transient'):
        self.connection = connection
        self._shared = None
        self.secret = secret
        self.mode = mode
        self._challenge = None

    async def _exchange(self, data, state):
        record({'stage': 'auth-request', 'authMode': self.mode,
                'authPhase': f'M{state-1}', 'authEndpoint': 'pair_setup'})
        try:
            response = await asyncio.wait_for(self.connection.post(
                '/pair-setup', headers={
                    'User-Agent': 'AirPlay/550.10',
                    'Content-Type': 'application/octet-stream',
                    'X-Apple-HKP': '4',
                }, body=write_tlv(data), allow_error=True), 8)
        except AuthenticationError:
            raise MacAuthenticationError(f'M{state}', 'access-denied', mode=self.mode) from None
        except (asyncio.TimeoutError, TimeoutError):
            raise MacAuthenticationError(f'M{state}', 'timeout', mode=self.mode) from None
        record({'stage': 'auth-response', 'authMode': self.mode,
                'authPhase': f'M{state}', 'httpStatus': response.code})
        if response.code in (401, 403):
            raise MacAuthenticationError(f'M{state}', 'access-denied',
                http_status=response.code, mode=self.mode)
        if response.code != 200:
            raise MacAuthenticationError(f'M{state}', f'http-{response.code}',
                http_status=response.code, mode=self.mode)
        try:
            return decode_pairing_response(response.body, state)
        except MacAuthenticationError as error:
            error.auth_mode = self.mode
            raise

    async def verify_credentials(self):
        await self.begin()
        await self.finish(self.secret)
        return True

    async def begin(self):
        self._shared = None
        fields = await self._exchange({
            TlvValue.Method: b'\x00', TlvValue.SeqNo: b'\x01',
            TlvValue.Flags: b'\x10',
        }, 2)
        salt = fields.get(TlvValue.Salt, b'')
        public = fields.get(TlvValue.PublicKey, b'')
        if not 16 <= len(salt) <= 64 or not 1 <= len(public) <= 384:
            raise MacAuthenticationError('M2', 'invalid-srp-parameters', mode=self.mode)
        self._challenge = (salt, public)

    async def finish(self, secret):
        if self._challenge is None:
            raise MacAuthenticationError('M3', 'pairing-not-started', mode=self.mode)
        salt, public = self._challenge
        self._challenge = None  # A rejected secret always needs a fresh challenge.
        if not isinstance(secret, str) or not 1 <= len(secret.encode('utf-8')) <= 256:
            raise MacAuthenticationError('M3', 'invalid-secret', mode=self.mode)
        context = SRPContext('Pair-Setup', secret,
                             prime=constants.PRIME_3072,
                             generator=constants.PRIME_3072_GEN,
                             hash_func=hashlib.sha512)
        client = SRPClientSession(context)
        try:
            client.process(public.hex(), salt.hex())
        except (ValueError, SRPException):
            raise MacAuthenticationError('M2', 'invalid-srp-public-key', mode=self.mode) from None
        fields = await self._exchange({
            TlvValue.SeqNo: b'\x03',
            TlvValue.PublicKey: binascii.unhexlify(client.public),
            TlvValue.Proof: binascii.unhexlify(client.key_proof),
        }, 4)
        proof = fields.get(TlvValue.Proof, b'')
        expected = binascii.unhexlify(client.key_proof_hash)
        if not hmac.compare_digest(proof, expected):
            raise MacAuthenticationError('M4', 'server-proof-mismatch', mode=self.mode)
        self._shared = binascii.unhexlify(client.key)
        record({'stage': 'auth-complete', 'authMode': self.mode,
                'authPhase': 'M4', 'authResult': 'success'})
        return True

    def encryption_keys(self, salt, output_info, input_info):
        if self._shared is None:
            raise MacAuthenticationError('encryption', 'not-verified')
        return (hkdf_expand(salt, output_info, self._shared),
                hkdf_expand(salt, input_info, self._shared))


class MacPinPairing:
    """Full HAP M1-M6 with checked server proofs and long-term identity."""
    device_provides_pin = True
    mode = 'pin'

    def __init__(self, connection):
        self.connection = connection
        self.srp = SRPAuthHandler()
        self.srp.initialize()
        self.credentials = None
        self.has_paired = False
        self._challenge = None

    async def _post(self, path, body=b'', state=None):
        phase = f'M{state}' if state else 'pin_start'
        record({'stage': 'auth-request', 'authMode': self.mode,
                'authPhase': f'M{state-1}' if state else phase, 'authEndpoint':
                    'pair_pin_start' if path == '/pair-pin-start' else 'pair_setup'})
        try:
            response = await asyncio.wait_for(self.connection.post(path,
                headers={'User-Agent': 'AirPlay/550.10', 'X-Apple-HKP': '3',
                         'X-Apple-Client-Name': 'BobTV',
                         'Connection': 'keep-alive',
                         **({'Content-Type': 'application/octet-stream'} if body
                            else {'Content-Length': '0'})},
                body=body, allow_error=True), 8)
        except (asyncio.TimeoutError, TimeoutError):
            raise MacAuthenticationError(phase, 'timeout', mode=self.mode) from None
        record({'stage': 'auth-response', 'authMode': self.mode,
                'authPhase': phase, 'httpStatus': response.code})
        if response.code not in (200, 204):
            raise MacAuthenticationError(phase, f'http-{response.code}',
                http_status=response.code, mode=self.mode)
        if state is not None:
            try:
                return decode_pairing_response(response.body, state)
            except MacAuthenticationError as error:
                error.auth_mode = self.mode
                raise

    async def begin(self):
        # Explicitly delimit the empty POST; pyatv otherwise omits its length.
        await self._post('/pair-pin-start')
        await self._begin_setup()

    async def _begin_setup(self):
        fields = await self._post('/pair-setup', write_tlv({
            TlvValue.Method: b'\x00', TlvValue.SeqNo: b'\x01'}), 2)
        salt, public = fields.get(TlvValue.Salt, b''), fields.get(TlvValue.PublicKey, b'')
        if not 16 <= len(salt) <= 64 or not 1 <= len(public) <= 384:
            raise MacAuthenticationError('M2', 'invalid-srp-parameters', mode=self.mode)
        self._challenge = (salt, public)

    async def finish(self, pin):
        if self._challenge is None:
            raise MacAuthenticationError('M3', 'pairing-not-started', mode=self.mode)
        if not isinstance(pin, str) or not 1 <= len(pin.encode('utf-8')) <= 256:
            raise MacAuthenticationError('M3', 'invalid-secret', mode=self.mode)
        if self.mode == 'pin' and (not pin.isascii() or not pin.isdigit() or len(pin) != 4):
            raise MacAuthenticationError('M3', 'invalid-pin', mode=self.mode)
        salt, public = self._challenge
        self._challenge = None
        self.srp.step1(pin)
        key, proof = self.srp.step2(public, salt)
        fields = await self._post('/pair-setup', write_tlv({
            TlvValue.SeqNo: b'\x03', TlvValue.PublicKey: key, TlvValue.Proof: proof}), 4)
        expected = binascii.unhexlify(self.srp._session.key_proof_hash)
        if not hmac.compare_digest(fields.get(TlvValue.Proof, b''), expected):
            raise MacAuthenticationError('M4', 'server-proof-mismatch', mode=self.mode)
        fields = await self._post('/pair-setup', write_tlv({
            TlvValue.SeqNo: b'\x05',
            TlvValue.EncryptedData: self.srp.step3(name='BobTV')}), 6)
        shared = binascii.unhexlify(self.srp.shared_key)
        session_key = hkdf_expand('Pair-Setup-Encrypt-Salt', 'Pair-Setup-Encrypt-Info', shared)
        try:
            decoded = chacha20.Chacha20Cipher8byteNonce(session_key, session_key).decrypt(
                fields[TlvValue.EncryptedData], nonce=b'PS-Msg06')
            identity = read_tlv(decoded)
            identifier, public_key, signature = (identity[TlvValue.Identifier],
                identity[TlvValue.PublicKey], identity[TlvValue.Signature])
            if not 1 <= len(identifier) <= 128 or len(public_key) != 32 or len(signature) != 64:
                raise ValueError('Invalid identity sizes')
            accessory = hkdf_expand('Pair-Setup-Accessory-Sign-Salt',
                'Pair-Setup-Accessory-Sign-Info', shared)
            Ed25519PublicKey.from_public_bytes(public_key).verify(
                signature, accessory + identifier + public_key)
        except (KeyError, ValueError, InvalidTag, InvalidSignature):
            raise MacAuthenticationError('M6', 'server-identity-invalid', mode=self.mode) from None
        self.credentials = HapCredentials(public_key, self.srp._auth_private,
            identifier, self.srp.pairing_id)
        self.has_paired = True
        record({'stage': 'auth-complete', 'authMode': self.mode,
                'authPhase': 'M6', 'authResult': 'success'})

    async def close(self):
        self._challenge = None
        self.srp = None
        self.connection.close()


class MacPasswordPairing(MacPinPairing):
    """Full HAP using the configured receiver password, without a PIN prompt.

    Native Mac password policy refuses transient HKP 4 before secret validation.
    Use HKP 3 M1-M6 and verify the resulting identity on fresh connections.
    """
    device_provides_pin = False
    mode = 'password'

    async def begin(self):
        await self._begin_setup()


class MacCredentialVerifier(AirPlayHapPairVerifyProcedure):
    async def verify_credentials(self):
        try:
            verified = await super().verify_credentials()
        except AuthenticationError as error:
            raise MacAuthenticationError('PV2', 'credential-verification-failed',
                mode='credentials') from error
        record({'stage': 'auth-complete', 'authMode': 'credentials',
                'authPhase': 'PV4', 'authResult': 'success'})
        return verified

    async def _send(self, data):
        state = int.from_bytes(data[TlvValue.SeqNo], 'little') + 1
        record({'stage': 'auth-request', 'authMode': 'credentials',
                'authPhase': f'PV{state-1}', 'authEndpoint': 'pair_verify'})
        response = await asyncio.wait_for(self.http.post('/pair-verify',
            headers={'User-Agent': 'AirPlay/550.10', 'X-Apple-HKP': '3',
                     'Content-Type': 'application/octet-stream'},
            body=write_tlv(data), allow_error=True), 8)
        record({'stage': 'auth-response', 'authMode': 'credentials',
                'authPhase': f'PV{state}', 'httpStatus': response.code})
        if response.code != 200:
            raise MacAuthenticationError(f'PV{state}', f'http-{response.code}',
                http_status=response.code, mode='credentials')
        try:
            decode_pairing_response(response.body, state)
        except MacAuthenticationError as error:
            error.stage = f'PV{state}'
            error.auth_mode = 'credentials'
            raise
        return response


async def authenticate(connection, credentials=None, password=None):
    """Enable control encryption only after both SRP proofs have been checked."""
    if password is not None:
        pairing = MacPasswordPairing(connection)
        await pairing.begin()
        await pairing.finish(password)
        credentials = pairing.credentials
        pairing.srp = None
    if credentials:
        parsed = parse_credentials(credentials) if isinstance(credentials, str) else credentials
        verifier = MacCredentialVerifier(connection, SRPAuthHandler(), parsed)
    else:
        verifier = MacTransientVerifier(connection)
    await verifier.verify_credentials()
    output_key, input_key = verifier.encryption_keys(
        'Control-Salt', 'Control-Write-Encryption-Key',
        'Control-Read-Encryption-Key')
    session = HAPSession()
    session.enable(output_key, input_key)
    connection.send_processor = session.encrypt
    connection.receive_processor = session.decrypt
    return verifier
