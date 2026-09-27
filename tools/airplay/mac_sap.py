"""Developer-only adapter for a source-built FPSAP authentication helper.

No content decryption is performed. The helper exchanges authentication records
over private pipes and is not shipped or enabled by the production bridge.
"""
import asyncio
import base64
import subprocess
import sys


async def helper_record(executable, operation, body=b''):
    options = {'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}
    process = await asyncio.create_subprocess_exec(
        executable, operation, stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, **options)
    try:
        output, _ = await asyncio.wait_for(process.communicate(base64.b64encode(body)), 8)
        if process.returncode or len(output) > 1024:
            raise RuntimeError('Media authentication helper failed')
        return base64.b64decode(output, validate=True)
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()


async def authenticate_media(rtsp, executable, diagnostic=None):
    m1 = await helper_record(executable, 'm1')
    response = await rtsp.exchange('POST', uri='/fp-setup',
        headers={'X-Apple-ET': '32'}, content_type='application/octet-stream',
        body=m1, allow_error=True)
    if response.code != 200 or not isinstance(response.body, bytes):
        raise RuntimeError(f'Media authentication M2 failed: HTTP {response.code}')
    if diagnostic:
        diagnostic({'stage': 'media-auth-M2', 'bytes': len(response.body),
                    'mode': response.body[13] if len(response.body) > 13 else None})
    m3 = await helper_record(executable, 'm3', response.body)
    response = await rtsp.exchange('POST', uri='/fp-setup',
        headers={'X-Apple-ET': '32'}, content_type='application/octet-stream',
        body=m3, allow_error=True)
    if response.code != 200:
        raise RuntimeError(f'Media authentication M4 failed: HTTP {response.code}')
    if diagnostic:
        diagnostic({'stage': 'media-auth-M4', 'status': response.code})
