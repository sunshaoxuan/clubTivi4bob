"""Close legacy anonymous catalog entry points after the client migration."""
import os

from fastapi import HTTPException
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import accounts
from internal_epg_auth import authorized

PRIVATE = {'Cache-Control': 'private, no-store', 'Vary': 'Authorization, Cookie'}


def protected(path):
    return (path == '/api/v1/sources' or
            path.startswith(('/api/v1/channel-catalog/', '/api/v1/epg/')))


def install(app):
    @app.middleware('http')
    async def authenticated_catalog(request, call_next):
        if os.environ.get('BOBTV_AUTHENTICATED_CATALOG') != '1' or not protected(request.url.path):
            return await call_next(request)
        try:
            # Full catalog snapshots are retained for administration and server
            # workers. Members obtain signed snapshots one region at a time.
            legacy = (request.url.path == '/api/v1/channel-catalog/manifest' or
                      request.url.path.startswith('/api/v1/channel-catalog/snapshots/') or
                      request.url.path == '/api/v1/sources')
            if not authorized(request.method, request.url.path, request.headers):
                user = await run_in_threadpool(accounts.current, request, admin=legacy)
                if not user['verified']:
                    raise HTTPException(403, 'verified_account_required')
        except HTTPException as exc:
            return JSONResponse({'detail': exc.detail}, status_code=exc.status_code,
                                headers=PRIVATE)
        response = await call_next(request)
        response.headers.update(PRIVATE)
        return response
