"""Experimental screen-video audio transport, bounded to 352 stereo samples.

ALAC verbatim and NTP RTP layouts cross-checked with AirSpan (MIT).
The encryption counter is 64-bit and does not repeat on RTP sequence wrap.
"""
import asyncio
import secrets
import struct
import time
from array import array

from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from pyatv.support.http import decode_bplist_from_body

SAMPLES = 352
RATE = 44100
PCM_BYTES = SAMPLES * 4
LATENCY = RATE // 4


def alac_verbatim(pcm):
    if len(pcm) != PCM_BYTES:
        raise ValueError('Audio requires exactly 352 stereo samples')
    samples = array('H')
    samples.frombytes(pcm)
    samples.byteswap()
    value = ((1 << 20) | 1) << (len(pcm) * 8)
    value |= int.from_bytes(samples.tobytes(), 'big')
    value = ((value << 3) | 7) << 6
    return value.to_bytes(PCM_BYTES + 4, 'big')


def audio_packet(pcm, key, sequence, rtp, stream_id, counter, first=False):
    header = struct.pack('>BBHII', 0x80, 0xe0 if first else 0x60,
                         sequence & 65535, rtp & 0xffffffff, stream_id & 0xffffffff)
    nonce = b'\0' * 4 + struct.pack('<Q', counter)
    encrypted = ChaCha20Poly1305(key).encrypt(nonce, alac_verbatim(pcm), header[4:12])
    return header + encrypted + nonce[4:]


def sync_packet(rtp, ntp, first=False):
    return struct.pack('>BBHIQI', 0x90 if first else 0x80, 0xd4, 7,
                       (rtp - LATENCY) & 0xffffffff, ntp, rtp & 0xffffffff)


class MacAudio:
    def __init__(self, protocol):
        self.protocol = protocol
        self.data = self.control = None
        self.sequence = secrets.randbits(16)
        self.rtp = secrets.randbits(32)
        self.stream_id = secrets.randbits(48)
        self.counter = 0
        self.last_sync = 0

    async def setup(self):
        loop = asyncio.get_running_loop()
        local = self.protocol.rtsp.connection.local_ip
        remote = self.protocol.rtsp.connection.remote_ip
        self.data, _ = await loop.create_datagram_endpoint(asyncio.DatagramProtocol, local_addr=(local, 0))
        self.control, _ = await loop.create_datagram_endpoint(asyncio.DatagramProtocol, local_addr=(local, 0))
        self.key = self.protocol._verifier._shared[:32]
        response = await asyncio.wait_for(self.protocol.rtsp.setup(body={'streams': [{
            'type': 96, 'streamConnectionID': self.stream_id, 'ct': 2, 'spf': SAMPLES,
            'sr': RATE, 'audioFormat': 0x40000, 'audioMode': 'default', 'usingScreen': True,
            'latencyMin': LATENCY, 'latencyMax': RATE * 2, 'shk': self.key,
            'isMedia': True, 'supportsDynamicStreamID': False,
            'controlPort': self.control.get_extra_info('sockname')[1],
            'dataPort': self.data.get_extra_info('sockname')[1]}]}), 8)
        stream = next(s for s in decode_bplist_from_body(response)['streams'] if s.get('type') == 96)
        for name in ('dataPort', 'controlPort'):
            if not isinstance(stream.get(name), int) or not 1 <= stream[name] <= 65535:
                raise ValueError('Invalid audio port')
        self.target = (remote, stream['dataPort'])
        self.control_target = (remote, stream['controlPort'])

    def send(self, pcm):
        now = time.monotonic()
        if now - self.last_sync >= .25 or self.counter == 0:
            # Type-96 NTP audio uses the NTP epoch, while native-Mac video
            # timestamps use the receiver's monotonic media clock.
            ntp = int((time.time() + 2208988800) * (1 << 32)) & ((1 << 64) - 1)
            self.control.sendto(sync_packet(self.rtp, ntp, self.counter == 0), self.control_target)
            self.last_sync = now
        self.data.sendto(audio_packet(pcm, self.key, self.sequence, self.rtp,
                                     self.stream_id, self.counter, self.counter == 0), self.target)
        self.sequence = (self.sequence + 1) & 65535
        self.rtp = (self.rtp + SAMPLES) & 0xffffffff
        self.counter += 1

    def close(self):
        for transport in (self.control, self.data):
            if transport:
                transport.close()
        self.control = self.data = None
