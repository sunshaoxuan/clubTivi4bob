import struct
import unittest
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from mac_audio import alac_verbatim, audio_packet, sync_packet, PCM_BYTES, LATENCY


class AudioTests(unittest.TestCase):
    def test_verbatim_preserves_samples(self):
        pcm = struct.pack('<h', -1234) * (PCM_BYTES // 2)
        bits = int.from_bytes(alac_verbatim(pcm), 'big') >> 6
        self.assertEqual(bits & 7, 7)
        bits >>= 3
        self.assertEqual((bits & ((1 << (PCM_BYTES * 8)) - 1)).to_bytes(PCM_BYTES, 'big'),
                         struct.pack('>h', -1234) * (PCM_BYTES // 2))
        self.assertEqual(bits >> (PCM_BYTES * 8), (1 << 20) | 1)

    def test_nonce_does_not_repeat_when_rtp_wraps(self):
        key = bytes(range(32))
        pcm = bytes(PCM_BYTES)
        first = audio_packet(pcm, key, 0, 0, 1, 0)
        later = audio_packet(pcm, key, 65536, 0, 1, 65536)
        self.assertNotEqual(first[-8:], later[-8:])
        decoded = ChaCha20Poly1305(key).decrypt(b'\0' * 4 + later[-8:], later[12:-8], later[4:12])
        self.assertEqual(decoded, alac_verbatim(pcm))

    def test_sync_wrap(self):
        packet = sync_packet(10, 1234, True)
        self.assertEqual(struct.unpack('>BBHIQI', packet),
                         (0x90, 0xd4, 7, (10-LATENCY) & 0xffffffff, 1234, 10))

    def test_bad_size(self):
        with self.assertRaises(ValueError):
            alac_verbatim(b'bad')
