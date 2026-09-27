import binascii
import hashlib
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

from srptools import SRPContext, SRPServerSession, constants
from pyatv.auth.hap_tlv8 import TlvValue, read_tlv, write_tlv
from pyatv.exceptions import AuthenticationError

from mac_auth import (MacAuthenticationError, MacTransientVerifier,
                      authenticate, decode_pairing_response)


class TransientReceiver:
    def __init__(self, bad_proof=False):
        context = SRPContext('Pair-Setup', '3939', prime=constants.PRIME_3072,
                             generator=constants.PRIME_3072_GEN,
                             hash_func=hashlib.sha512, bits_salt=128)
        _, verifier, self.salt = context.get_user_data_triplet()
        self.server = SRPServerSession(context, verifier)
        self.bad_proof = bad_proof
        self.paths = []
        self.send_processor = None
        self.receive_processor = None

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
            assert self.server.verify_proof(fields[TlvValue.Proof].hex().encode())
            proof = binascii.unhexlify(self.server.key_proof_hash)
            response = {TlvValue.SeqNo: b'\x04',
                        TlvValue.Proof: b'bad' if self.bad_proof else proof}
        return SimpleNamespace(code=200, body=write_tlv(response))


class MacAuthTests(unittest.IsolatedAsyncioTestCase):
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
