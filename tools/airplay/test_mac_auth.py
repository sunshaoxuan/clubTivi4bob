import binascii
import hashlib
import hmac
import contextlib
import io
import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from srptools import SRPContext, SRPServerSession, constants
from pyatv.auth.hap_tlv8 import TlvValue, read_tlv, write_tlv
from pyatv.exceptions import AuthenticationError

from mac_auth import (MacAuthenticationError, MacTransientVerifier,
                      MacPinPairing, MacPasswordPairing,
                      authenticate, decode_pairing_response)
from pyatv.protocols.airplay.server_auth import BaseAirPlayServerAuth
from pyatv.support.http import HttpRequest


class TransientReceiver:
    def __init__(self, bad_proof=False, secret='3939'):
        context = SRPContext('Pair-Setup', secret, prime=constants.PRIME_3072,
                             generator=constants.PRIME_3072_GEN,
                             hash_func=hashlib.sha512, bits_salt=128)
        _, verifier, self.salt = context.get_user_data_triplet()
        self.server = SRPServerSession(context, password_verifier=verifier)
        self.bad_proof = bad_proof
        self.paths = []
        self.send_processor = None
        self.receive_processor = None

    def close(self):
        pass

    async def post(self, path, headers, body, allow_error):
        self.paths.append(path)
        fields = read_tlv(body)
        if fields[TlvValue.SeqNo] == b'\x01':
            assert fields[TlvValue.Flags] == b'\x10'
            response = {TlvValue.SeqNo: b'\x02',
                        TlvValue.Salt: binascii.unhexlify(self.salt),
                        TlvValue.PublicKey: binascii.unhexlify(self.server.public)}
        else:
            self.server.process(fields[TlvValue.PublicKey].hex(), self.salt)
            if not hmac.compare_digest(binascii.unhexlify(self.server.key_proof), fields[TlvValue.Proof]):
                return SimpleNamespace(code=200, body=write_tlv({
                    TlvValue.SeqNo: b'\x04', TlvValue.Error: b'\x02'}))
            proof = binascii.unhexlify(self.server.key_proof_hash)
            response = {TlvValue.SeqNo: b'\x04',
                        TlvValue.Proof: b'bad' if self.bad_proof else proof}
        return SimpleNamespace(code=200, body=write_tlv(response))


class PinServer(BaseAirPlayServerAuth):
    def enable_encryption(self, output_key, input_key):
        pass


class PinReceiver:
    def __init__(self):
        self.server = PinServer('Test Mac', pin='0123')
        self.send_processor = self.receive_processor = None
        self.reject_verify = False

    async def post(self, path, headers, body=b'', allow_error=True):
        if path == '/pair-pin-start':
            assert headers['Content-Length'] == '0'
        if self.reject_verify and path == '/pair-verify' and read_tlv(body)[TlvValue.SeqNo] == b'\x03':
            return SimpleNamespace(code=200, body=write_tlv({TlvValue.SeqNo: b'\x04', TlvValue.Error: b'\x02'}))
        request = HttpRequest('POST', path, 'HTTP', '1.1', headers, body)
        return {'/pair-pin-start': self.server.handle_pair_pin_start,
                '/pair-setup': self.server.handle_pair_setup,
                '/pair-verify': self.server.handle_pair_verify}[path](request)

    def close(self):
        pass


class MacAuthTests(unittest.IsolatedAsyncioTestCase):
    async def test_password_is_used_for_real_srp_and_is_not_in_diagnostics(self):
        receiver = TransientReceiver(secret='Test password 9!')
        session = MacPasswordPairing(receiver)
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, \
             patch.dict(os.environ, {'LOCALAPPDATA': folder}), contextlib.redirect_stdout(output):
            await session.begin()
            await session.finish('Test password 9!')
            persisted = (Path(folder) / 'BobTV/AirPlay/native-cast.log').read_text()
        for text in (persisted, output.getvalue()):
            self.assertNotIn('Test password 9!', text)
            self.assertNotIn(receiver.server.key.decode('ascii'), text)
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertTrue(any(e.get('authResult') == 'success' for e in events))
        self.assertTrue(session.has_paired)
        self.assertEqual(session.verifier._shared, binascii.unhexlify(receiver.server.key))

    async def test_wrong_password_never_enables_encryption(self):
        receiver = TransientReceiver(secret='actual password')
        # The receiver rejects the mismatching SRP proof.
        session = MacPasswordPairing(receiver)
        await session.begin()
        with self.assertRaises(MacAuthenticationError):
            await session.finish('incorrect password')
        self.assertFalse(session.has_paired)
        self.assertIsNone(receiver.send_processor)

    async def test_pin_setup_identity_and_saved_credential_verification(self):
        receiver = PinReceiver()
        session = MacPinPairing(receiver)
        await session.begin()
        await session.finish('0123')
        self.assertTrue(session.has_paired)
        self.assertEqual(session.credentials.atv_id, receiver.server.unique_id)
        verified = await authenticate(receiver, credentials=str(session.credentials))
        self.assertTrue(callable(receiver.send_processor))
        self.assertEqual(len(verified.encryption_keys('s', 'w', 'r')[0]), 32)

    async def test_bad_pin_and_final_verify_rejection_are_terminal(self):
        receiver = PinReceiver()
        session = MacPinPairing(receiver)
        await session.begin()
        with self.assertRaises(MacAuthenticationError):
            await session.finish('9876')
        self.assertFalse(session.has_paired)
        receiver = PinReceiver()
        session = MacPinPairing(receiver)
        await session.begin()
        await session.finish('0123')
        receiver.reject_verify = True
        with self.assertRaises(MacAuthenticationError):
            await authenticate(receiver, credentials=session.credentials)
        self.assertIsNone(receiver.send_processor)

    async def test_real_srp_proofs_and_control_keys(self):
        receiver = TransientReceiver()
        verifier = await authenticate(receiver)
        self.assertEqual(verifier._shared, binascii.unhexlify(receiver.server.key))
        self.assertEqual(receiver.paths, ['/pair-setup', '/pair-setup'])
        self.assertTrue(callable(receiver.send_processor))
        self.assertTrue(callable(receiver.receive_processor))
        keys = verifier.encryption_keys('Events-Salt', 'Events-Read-Encryption-Key',
                                        'Events-Write-Encryption-Key')
        self.assertEqual([len(key) for key in keys], [32, 32])
        self.assertNotEqual(*keys)

    async def test_bad_proof_never_enables_encryption(self):
        receiver = TransientReceiver(bad_proof=True)
        with self.assertRaisesRegex(MacAuthenticationError, 'server-proof-mismatch'):
            await authenticate(receiver)
        self.assertIsNone(receiver.send_processor)
        self.assertIsNone(receiver.receive_processor)

    async def test_access_denied_does_not_retry_or_request_pin(self):
        receiver = SimpleNamespace(post=AsyncMock(side_effect=AuthenticationError('secret')))
        with self.assertRaisesRegex(MacAuthenticationError, '^M2: access-denied$'):
            await authenticate(receiver)
        self.assertEqual(receiver.post.await_count, 1)
        self.assertEqual(receiver.post.call_args.args[0], '/pair-setup')

    async def test_missing_proof_and_wrong_state_rejected(self):
        for body in (write_tlv({TlvValue.SeqNo: b'\x03'}), b'\x06\x02\x02', b'\x06'):
            with self.assertRaises(MacAuthenticationError):
                decode_pairing_response(body, 2)

    async def test_keys_unavailable_before_verification(self):
        verifier = MacTransientVerifier(None)
        with self.assertRaisesRegex(MacAuthenticationError, 'not-verified'):
            verifier.encryption_keys('salt', 'write', 'read')

    async def test_receiver_backoff_is_terminal(self):
        receiver = SimpleNamespace(post=AsyncMock(return_value=SimpleNamespace(
            code=200, body=write_tlv({TlvValue.SeqNo:b'\x02', TlvValue.Error:b'\x03'}))))
        with self.assertRaisesRegex(MacAuthenticationError, 'receiver-error-3'):
            await authenticate(receiver)
        self.assertEqual(receiver.post.await_count, 1)


if __name__ == '__main__':
    unittest.main()
