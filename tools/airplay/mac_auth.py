"""Experimental native-Mac transient authentication, separate from PIN pairing.

This does not implement Apple-account authentication and must not fall back to
PIN guesses when the receiver denies access. Production Mac casting remains
disabled until the subsequent video session is validated on a physical receiver.
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


class MacAuthenticationError(Exception):
    """Safe diagnostic containing no response bodies, keys or source URLs."""

    def __init__(self, stage, reason):
        self.stage = stage
        self.reason = reason
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
        raise MacAuthenticationError(stage, f'receiver-error-{code}')
    if fields.get(TlvValue.SeqNo) != bytes([state]):
        raise MacAuthenticationError(stage, 'unexpected-state')
    return fields


class MacTransientVerifier(PairVerifyProcedure):
    """One ephemeral SRP exchange without requesting an on-screen PIN.

    3939 is the protocol's transient-pairing value, not a user PIN. Only use
    this on receivers configured to permit transient access. Verify the remote
    SRP proof before enabling either encrypted control or event channels.
    """

    def __init__(self, connection):
        self.connection = connection
        self._shared = None

    async def _exchange(self, data, state):
        try:
            response = await asyncio.wait_for(self.connection.post(
                '/pair-setup', headers={
                    'User-Agent': 'AirPlay/550.10',
                    'Content-Type': 'application/octet-stream',
                    'X-Apple-HKP': '4',
                }, body=write_tlv(data), allow_error=True), 8)
        except AuthenticationError:
            raise MacAuthenticationError(f'M{state}', 'access-denied') from None
        except (asyncio.TimeoutError, TimeoutError):
            raise MacAuthenticationError(f'M{state}', 'timeout') from None
        if response.code in (401, 403):
            raise MacAuthenticationError(f'M{state}', 'access-denied')
        if response.code != 200:
            raise MacAuthenticationError(f'M{state}', f'http-{response.code}')
        return decode_pairing_response(response.body, state)

    async def verify_credentials(self):
        self._shared = None
        fields = await self._exchange({
            TlvValue.Method: b'\x00', TlvValue.SeqNo: b'\x01',
            TlvValue.Flags: b'\x10',
        }, 2)
        salt = fields.get(TlvValue.Salt, b'')
        public = fields.get(TlvValue.PublicKey, b'')
        if not 16 <= len(salt) <= 64 or not 1 <= len(public) <= 384:
            raise MacAuthenticationError('M2', 'invalid-srp-parameters')
        context = SRPContext('Pair-Setup', '3939',
                             prime=constants.PRIME_3072,
                             generator=constants.PRIME_3072_GEN,
                             hash_func=hashlib.sha512)
        client = SRPClientSession(context)
        try:
            client.process(public.hex(), salt.hex())
        except (ValueError, SRPException):
            raise MacAuthenticationError('M2', 'invalid-srp-public-key') from None
        fields = await self._exchange({
            TlvValue.SeqNo: b'\x03',
            TlvValue.PublicKey: binascii.unhexlify(client.public),
            TlvValue.Proof: binascii.unhexlify(client.key_proof),
        }, 4)
        proof = fields.get(TlvValue.Proof, b'')
        expected = binascii.unhexlify(client.key_proof_hash)
        if not hmac.compare_digest(proof, expected):
            raise MacAuthenticationError('M4', 'server-proof-mismatch')
        self._shared = binascii.unhexlify(client.key)
        return True

    def encryption_keys(self, salt, output_info, input_info):
        if self._shared is None:
            raise MacAuthenticationError('encryption', 'not-verified')
        return (hkdf_expand(salt, output_info, self._shared),
                hkdf_expand(salt, input_info, self._shared))


async def authenticate(connection):
    """Enable control encryption only after both SRP proofs have been checked."""
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
