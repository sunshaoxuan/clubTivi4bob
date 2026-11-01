"""Generate an owned moving-colour AVI without any audio stream or network."""
import struct
import sys
from pathlib import Path


def chunk(tag, data):
    return tag + struct.pack('<I', len(data)) + data + (b'\0' if len(data) % 2 else b'')


target = Path(sys.argv[1])
if target.exists():
    raise SystemExit('Preserve the existing fixture')
width, height, count, fps = 160, 96, 450, 5
size = width * height * 3
avih = struct.pack('<14I', 1000000 // fps, size * fps, 0, 0, count, 0, 1,
                   size, width, height, 0, 0, 0, 0)
strh = struct.pack('<4s4sIHH8I4h', b'vids', b'DIB ', 0, 0, 0, 0, 1, fps,
                   0, count, size, 0xffffffff, 0, 0, 0, width, height)
strf = struct.pack('<IiiHHIIiiII', 40, width, height, 1, 24, 0, size, 0, 0, 0, 0)
headers = chunk(b'LIST', b'hdrl' + chunk(b'avih', avih) +
                chunk(b'LIST', b'strl' + chunk(b'strh', strh) + chunk(b'strf', strf)))
frames = b''.join(chunk(b'00db', bytes([n % 256, (n * 3) % 256, 190]) *
                        (width * height)) for n in range(count))
body = b'AVI ' + headers + chunk(b'LIST', b'movi' + frames)
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
print('Created owned silent video fixture, 160x96, 90 seconds, no audio stream')
