"""Experimental bounded H.264 video-only transport; never captures a desktop.

Wire layout cross-checked against the MIT-licensed AirSpan implementation.
Not enabled in the production bridge until physical playback is verified.
"""
import asyncio
import contextlib
import re
import secrets
import struct
import time

from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from pyatv.protocols.raop.protocols import StreamContext, TimingServer
from pyatv.support.http import http_connect, decode_bplist_from_body
from pyatv.support.rtsp import RtspSession
from mac_video import MacVideoProtocol
from mac_audio import MacAudio, PCM_BYTES, SAMPLES, RATE


def parse_test_video(data):
    if len(data) > 16 * 1024 * 1024:
        raise ValueError('Test video exceeds bounded input')
    nals = [n for n in re.split(b'\x00\x00\x00?\x01', data) if n]
    sps = next(n for n in nals if n[0] & 31 == 7)
    pps = next(n for n in nals if n[0] & 31 == 8)
    if len(sps) < 4 or max(len(sps), len(pps)) > 65535:
        raise ValueError('Invalid H.264 configuration')
    config = (b'\x01' + sps[1:4] + b'\xff\xe1' + struct.pack('>H', len(sps)) + sps
              + b'\x01' + struct.pack('>H', len(pps)) + pps)
    frames, current = [], []
    for nal in nals:
        kind = nal[0] & 31
        if kind == 9 and current:
            frames.append(current)
            current = []
        if 1 <= kind <= 5:
            current.append(nal)
    if current:
        frames.append(current)
    if not frames or len(frames) > 500:
        raise ValueError('Invalid bounded frame count')
    return config, frames


def codec_packet(config, timestamp, width=640, height=360):
    header = bytearray(128)
    struct.pack_into('<I', header, 0, len(config))
    header[4:8] = b'\x01\x00\x16\x01'
    struct.pack_into('<Q', header, 8, timestamp)
    for offset in (16, 40, 56):
        struct.pack_into('<ff', header, offset, width, height)
    return bytes(header) + config


def frame_packet(nals, timestamp, key, counter):
    payload = b''.join(struct.pack('>I', len(n)) + n for n in nals)
    if len(payload) > 2 * 1024 * 1024 or not payload:
        raise ValueError('Invalid frame size')
    header = bytearray(128)
    struct.pack_into('<I', header, 0, len(payload) + 16)
    header[5] = 0x10 if any(n[0] & 31 == 5 for n in nals) else 0
    struct.pack_into('<Q', header, 8, timestamp)
    nonce = b'\x00' * 4 + struct.pack('<Q', counter)
    return bytes(header) + ChaCha20Poly1305(key).encrypt(nonce, payload, bytes(header))


async def play_test_frames(address, port, data, helper, diagnostic, pcm=None, source=None, timing_ready=None):
    video_iterator = audio_iterator = None
    width, height = 640, 360
    if source:
        video_iterator = source.video().__aiter__()
        audio_iterator = source.audio().__aiter__()
        (config, first_frame), first_audio = await asyncio.wait_for(asyncio.gather(
            video_iterator.__anext__(), audio_iterator.__anext__()), 15)
        frames = None
        width, height = source.width, source.height
    else:
        config, frames = parse_test_video(data)
    connection = await asyncio.wait_for(http_connect(address, port), 8)
    protocol = MacVideoProtocol(StreamContext(), RtspSession(connection))
    protocol.frame_stream = True
    protocol.media_auth_helper = helper
    protocol.diagnostic = diagnostic
    transport = writer = audio = audio_task = None
    class ReceiverTiming(TimingServer):
        requests = 0
        def datagram_received(self, data, addr):
            if addr[0] != address or len(data) != 32:
                return
            self.requests += 1
            super().datagram_received(data, addr)
            if self.requests == 1:
                diagnostic({'stage': 'timing-request-replied'})
    try:
        transport, timer = await asyncio.get_running_loop().create_datagram_endpoint(
            ReceiverTiming, local_addr=(connection.local_ip, 0))
        if timing_ready:
            await timing_ready(timer.port)
        await asyncio.wait_for(protocol._setup_base(timer.port), 20)
        diagnostic({'stage': 'frame-base-setup', 'status': 200})
        stream_id = secrets.randbits(48)
        output, input_key = protocol._verifier.encryption_keys(
            'Control-Salt', 'Control-Write-Encryption-Key', 'Control-Read-Encryption-Key')
        response = await asyncio.wait_for(protocol.rtsp.setup(body={'streams': [{
            'type': 110, 'streamConnectionID': stream_id, 'latencyMs': 75,
            'timestampInfo': [{'name': n} for n in ('SubSu', 'BePxT', 'AfPxT', 'BefEn', 'EmEnc')],
            'shk': output[:16], 'shiv': input_key[:16]}]}), 8)
        info = decode_bplist_from_body(response)
        streams = info.get('streams', [])
        video = next(s for s in streams if s.get('type') == 110)
        data_port = video.get('dataPort')
        if not isinstance(data_port, int) or not 1 <= data_port <= 65535:
            raise ValueError('Invalid receiver video port')
        diagnostic({'stage': 'frame-stream-setup', 'status': response.code})
        key, _ = protocol._verifier.encryption_keys('DataStream-Salt' + str(stream_id),
            'DataStream-Output-Encryption-Key', 'DataStream-Input-Encryption-Key')
        reader, writer = await asyncio.wait_for(asyncio.open_connection(address, data_port), 8)
        if pcm or source:
            audio = MacAudio(protocol)
            await audio.setup()
            diagnostic({'stage': 'audio-stream-setup', 'status': 200})
        await protocol.start_feedback()
        record_headers = {'Range': 'npt=0-'}
        if audio:
            record_headers['RTP-Info'] = f'seq={audio.sequence};rtptime={audio.rtp}'
        await asyncio.wait_for(protocol.rtsp.record(headers=record_headers), 8)
        if audio:
            response = await asyncio.wait_for(protocol.rtsp.set_parameter('volume', '-12.0'), 5)
            diagnostic({'stage': 'audio-volume', 'status': response.code})
        start = time.monotonic()
        epoch = protocol.media_time() + (.25 if audio else .075)
        def timestamp(index=0):
            return int((epoch + index / 25) * (1 << 32)) & ((1 << 64) - 1)
        writer.write(codec_packet(config, timestamp(), width, height))
        await asyncio.wait_for(writer.drain(), 2)
        if audio:
            async def send_audio():
                index = 0
                while source or index < len(pcm) // PCM_BYTES:
                    if source:
                        try:
                            packet = first_audio if index == 0 else await audio_iterator.__anext__()
                        except StopAsyncIteration:
                            return
                    else:
                        packet = pcm[index * PCM_BYTES:(index + 1) * PCM_BYTES]
                    await asyncio.sleep(max(0, start + index * SAMPLES / RATE - time.monotonic()))
                    if time.monotonic() - (start + index * SAMPLES / RATE) > 2:
                        raise TimeoutError('Audio source fell behind playback')
                    audio.send(packet)
                    index += 1
            audio_task = asyncio.create_task(send_audio())
        index = 0
        while source or index < len(frames):
            if audio_task and audio_task.done():
                await audio_task
                if source:
                    break
            if source:
                try:
                    next_config, nals = (config, first_frame) if index == 0 else await video_iterator.__anext__()
                except StopAsyncIteration:
                    break
                if next_config != config:
                    config = next_config
                    writer.write(codec_packet(config, timestamp(index), width, height))
            else:
                nals = frames[index]
            await asyncio.sleep(max(0, start + index / 25 - time.monotonic()))
            if time.monotonic() - (start + index / 25) > 2:
                raise TimeoutError('Video source fell behind playback')
            if reader.at_eof():
                raise ConnectionError('Receiver closed video channel')
            writer.write(frame_packet(nals, timestamp(index), key, index))
            await asyncio.wait_for(writer.drain(), 2)
            index += 1
            if index == 25 or index % 750 == 0:
                diagnostic({'stage': 'frame-progress', 'count': index,
                            'audioPackets': audio.counter if audio else 0})
        diagnostic({'stage': 'frames-sent', 'count': index, 'playbackVerified': False})
        if audio_task:
            await audio_task
            diagnostic({'stage': 'audio-sent', 'packets': audio.counter})
        await asyncio.sleep(2)
    finally:
        if audio_task and not audio_task.done():
            audio_task.cancel()
            await asyncio.gather(audio_task, return_exceptions=True)
        if audio:
            audio.close()
        feedback = protocol._feedback_task
        if writer:
            writer.close()
            with contextlib.suppress(Exception):
                await asyncio.wait_for(writer.wait_closed(), 2)
        if getattr(protocol, 'session_established', False):
            try:
                response = await asyncio.wait_for(protocol.rtsp.exchange('TEARDOWN', allow_error=True), 2)
                diagnostic({'stage': 'frame-teardown', 'status': response.code})
            except Exception as error:
                diagnostic({'stage': 'frame-teardown', 'errorType': type(error).__name__})
        protocol.teardown()
        if transport:
            diagnostic({'stage': 'timing-cleanup', 'requests': timer.requests})
            transport.close()
        connection.close()
        if feedback:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await feedback
