"""Small uncompressed AVI fixture, generated without network or FFmpeg."""
import struct
import sys
from pathlib import Path

def chunk(tag, data):
    return tag + struct.pack('<I', len(data)) + data + (b'\0' if len(data) % 2 else b'')

width, height, count, fps = 64, 48, 75, 25
frame_size = width * height * 3
avih = struct.pack('<14I', 1000000//fps, frame_size*fps, 0, 0, count, 0, 1, frame_size, width, height, 0, 0, 0, 0)
strh = struct.pack('<4s4sIHH8I4h', b'vids', b'DIB ', 0, 0, 0, 0, 1, fps, 0, count, frame_size, 0xffffffff, 0, 0, 0, width, height)
strf = struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24, 0, frame_size, 0, 0, 0, 0)
headers = chunk(b'LIST', b'hdrl' + chunk(b'avih', avih) + chunk(b'LIST', b'strl' + chunk(b'strh', strh) + chunk(b'strf', strf)))
frames = b''.join(chunk(b'00db', bytes([frame*3 % 256, 90, 190]) * (width*height)) for frame in range(count))
body = b'AVI ' + headers + chunk(b'LIST', b'movi' + frames)
Path(sys.argv[1]).write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
