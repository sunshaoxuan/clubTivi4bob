import struct
import unittest
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from mac_frames import parse_test_video, codec_packet, frame_packet


class FrameTests(unittest.TestCase):
    def test_annexb_configuration_and_frame_boundaries(self):
        nals = [b'\x67\x42\x00\x1e', b'\x68ab', b'\x09x', b'\x65abc',
                b'\x09x', b'\x41def']
        config, frames = parse_test_video(b''.join(b'\x00\x00\x00\x01' + n for n in nals))
        self.assertEqual(config[:6], b'\x01\x42\x00\x1e\xff\xe1')
        self.assertEqual(frames, [[b'\x65abc'], [b'\x41def']])

    def test_authenticated_frame_roundtrip_and_nonce_uniqueness(self):
        key = bytes(range(32))
        packet = frame_packet([b'\x65abc'], 1234, key, 7)
        self.assertEqual(packet[5], 16)
        self.assertEqual(struct.unpack_from('<Q', packet, 8)[0], 1234)
        plain = ChaCha20Poly1305(key).decrypt(b'\x00' * 4 + struct.pack('<Q', 7),
                                            packet[128:], packet[:128])
        self.assertEqual(plain, b'\x00\x00\x00\x04\x65abc')
        self.assertNotEqual(packet, frame_packet([b'\x65abc'], 1234, key, 8))

    def test_codec_dimensions(self):
        packet = codec_packet(b'abc', 123)
        self.assertEqual(packet[4:8], b'\x01\x00\x16\x01')
        self.assertEqual(struct.unpack_from('<ff', packet, 16), (640, 360))
        self.assertEqual(packet[128:], b'abc')

    def test_empty_frame_rejected(self):
        with self.assertRaises(ValueError):
            frame_packet([], 0, bytes(32), 0)


if __name__ == '__main__':
    unittest.main()
