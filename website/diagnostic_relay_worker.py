"""Bounded, restartable forwarding of already-consented diagnostic batches."""
import asyncio
import ipaddress
import json
import os
import time
from email.utils import parsedate_to_datetime
from pathlib import Path

import httpx

from diagnostic_store import DiagnosticStore
from resource_nodes import signature

PATH = '/api/v1/diagnostics/batches'


def store():
    return DiagnosticStore(Path(os.environ.get('BOBTV_RELAY_DATA_DIR', '/var/lib/bobtv-relay')) / 'diagnostics-v2',
                           maximum=128 * 1024 * 1024, state='relay_stored')


async def forward(client, queue, secret, address, target, extensions=None, now=None):
    now = int(time.time()) if now is None else now
    done = failed = 0
    for row in await asyncio.to_thread(queue.due, 5, now):
        stamp = str(int(time.time()))
        headers = {'Host': 'bobtv.briconbric.com', 'Content-Type': 'application/json',
                   'Idempotency-Key': row['id'], 'User-Agent': 'BobTV-diagnostic-relay/2',
                   'X-BobTV-Relay-Node': 'cndrp', 'X-BobTV-Relay-Client': address,
                   'X-BobTV-Relay-Time': stamp,
                   'X-BobTV-Relay-Auth': signature(secret, 'POST', PATH, address, stamp)}
        try:
            response = await client.post(target + PATH, content=row['body'],
                                         headers=headers, extensions=extensions or {})
            if response.status_code in (200, 201):
                receipt = response.json()
                if (receipt.get('id') != row['id'] or receipt.get('state') != 'origin_accepted'
                        or 'no-store' not in response.headers.get('cache-control', '')):
                    raise ValueError('Unverified diagnostic acknowledgment')
                await asyncio.to_thread(queue.forwarded, row['id'])
                done += 1
            else:
                retry = response.headers.get('retry-after', '')
                retry_seconds = int(retry) if retry.isdecimal() else 0
                if retry and not retry.isdecimal():
                    try:
                        retry_seconds = max(0, int(parsedate_to_datetime(retry).timestamp() - now))
                    except (ValueError, TypeError, OverflowError):
                        pass
                await asyncio.to_thread(queue.retry, row['id'],
                                        permanent=response.status_code in (413, 415, 422),
                                        retry_after=retry_seconds, now=now)
                failed += 1
        except (httpx.HTTPError, ValueError, TypeError):
            await asyncio.to_thread(queue.retry, row['id'], now=now)
            failed += 1
    return {'forwarded': done, 'deferred': failed}


async def main():
    from resource_relay import origin_url, origin_extensions
    secret = os.environ.get('BOBTV_RELAY_SECRET', '')
    if len(secret) < 64:
        raise RuntimeError('Relay authentication unavailable')
    address = str(ipaddress.ip_address(os.environ.get('BOBTV_RELAY_PUBLIC_IP', '121.43.197.117')))
    queue = store()
    await asyncio.to_thread(queue.prune)
    async with httpx.AsyncClient(follow_redirects=False, trust_env=False,
                                timeout=httpx.Timeout(20, connect=5)) as client:
        print(json.dumps(await forward(client, queue, secret, address, origin_url(''), origin_extensions())))


if __name__ == '__main__':
    asyncio.run(main())
