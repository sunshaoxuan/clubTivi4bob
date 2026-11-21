"""Standalone read-only EPG API; shares the authoritative primary database."""
from fastapi import FastAPI

from epg_catalog import router
from catalog_access import install

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
install(app)
app.include_router(router)
