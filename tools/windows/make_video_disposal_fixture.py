"""Small uncompressed AVI fixture, generated without network or FFmpeg."""
import struct
import math
import sys
from pathlib import Path

def chunk(tag, data):
    return tag + struct.pack('<I', len(data)) + data + (b'\0' if len(data) % 2 else b'')

width, height, count, fps = 640, 360, 75, 25
sample_rate, samples_per_frame = 48000, 1920
frame_size = width * height * 3
avih = struct.pack('<14I', 1000000//fps, frame_size*fps, 0, 0, count, 0, 2, frame_size, width, height, 0, 0, 0, 0)
strh = struct.pack('<4s4sIHH8I4h', b'vids', b'DIB ', 0, 0, 0, 0, 1, fps, 0, count, frame_size, 0xffffffff, 0, 0, 0, width, height)
strf = struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24, 0, frame_size, 0, 0, 0, 0)
audio_header = struct.pack('<4s4sIHH8I4h', b'auds', b'\0'*4, 0, 0, 0,
    0, 4, sample_rate*4, 0, count*samples_per_frame, samples_per_frame*4,
    0xffffffff, 4, 0, 0, 0, 0)
audio_format = struct.pack('<HHIIHH', 1, 2, sample_rate, sample_rate*4, 4, 16)
headers = chunk(b'LIST', b'hdrl' + chunk(b'avih', avih) +
    chunk(b'LIST', b'strl' + chunk(b'strh', strh) + chunk(b'strf', strf)) +
    chunk(b'LIST', b'strl' + chunk(b'strh', audio_header) + chunk(b'strf', audio_format)))
frames = b''
for frame in range(count):
    frames += chunk(b'00db', bytes([frame*3 % 256, 90, 190]) * (width*height))
    pcm = b''.join(struct.pack('<hh', *(2*[int(1000*math.sin(2*math.pi*440*n/sample_rate))]))
        for n in range(frame*samples_per_frame, (frame+1)*samples_per_frame))
    frames += chunk(b'01wb', pcm)
body = b'AVI ' + headers + chunk(b'LIST', b'movi' + frames)
Path(sys.argv[1]).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
