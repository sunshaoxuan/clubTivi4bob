"""Safe, rate-limited failure diagnostics keep the public API contract intact."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sqlite3
import sys

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

sys.path.insert(0,str(Path(__file__).parents[1]))
import epg_catalog as api
from epg_ingest import EpgError


@pytest.fixture(autouse=True)
def reset_diagnostics(monkeypatch):
    monkeypatch.setattr(api,'_failure_log_times',{})


def sqlite_error(code):
    error=sqlite3.OperationalError('sensitive token /private/source?key=secret')
    error.sqlite_errorcode=code
    return error


@pytest.mark.parametrize(('error','reason','code'),[
    (sqlite_error(sqlite3.SQLITE_BUSY),'database_busy','5'),
    (sqlite_error(sqlite3.SQLITE_BUSY | (1<<8)),'database_busy','5'),
    (sqlite_error(sqlite3.SQLITE_LOCKED),'database_locked','6'),
    (sqlite_error(sqlite3.SQLITE_IOERR),'database_error','10'),
    (sqlite3.OperationalError('sensitive token'),'database_error','none'),
    (EpgError('invalid_publication_receipt'),'invalid_publication_receipt','none'),
    (EpgError('sensitive token'),'publication_validation_error','none'),
    (OSError('/private/path key=secret'),'filesystem_error','none'),
    (ValueError('sensitive programme body'),'publication_value_error','none'),
])
def test_public_contract_and_safe_classification(tmp_path,monkeypatch,caplog,error,reason,code):
    path=tmp_path/'fixture.sqlite3'
    sqlite3.connect(path).close()
    monkeypatch.setattr(api,'DATABASE',path)
    def broken(conn):
        raise error
    monkeypatch.setattr(api,'active_manifest',broken)
    app=FastAPI()
    app.include_router(api.router)
    with caplog.at_level('WARNING',logger='bobtv.epg.manifest'):
        response=TestClient(app).get('/api/v1/epg/manifest')
    assert response.status_code==503
    assert response.json()=={'error':'epg_publication_unavailable'}
    assert response.headers['cache-control']=='no-store, max-age=0'
    assert response.headers['pragma']=='no-cache'
    messages=[record.getMessage() for record in caplog.records if record.name=='bobtv.epg.manifest']
    assert messages==['epg_manifest_unavailable reason='+reason+' sqlite_primary_code='+code]
    assert not any(record.exc_info for record in caplog.records)
    assert 'secret' not in caplog.text and 'sensitive' not in caplog.text and '/private' not in caplog.text


def test_repeated_errors_are_limited_until_next_minute(monkeypatch,caplog):
    clock=[100.0]
    monkeypatch.setattr(api,'monotonic',lambda:clock[0])
    with caplog.at_level('WARNING',logger='bobtv.epg.manifest'):
        api._record_manifest_failure(sqlite_error(sqlite3.SQLITE_BUSY))
        clock[0]=159.9
        api._record_manifest_failure(sqlite_error(sqlite3.SQLITE_BUSY))
        clock[0]=160
        api._record_manifest_failure(sqlite_error(sqlite3.SQLITE_BUSY))
    assert len(caplog.records)==2


def test_distinct_failure_reasons_are_not_suppressed(caplog):
    with caplog.at_level('WARNING',logger='bobtv.epg.manifest'):
        api._record_manifest_failure(sqlite_error(sqlite3.SQLITE_BUSY))
        api._record_manifest_failure(EpgError('invalid_publication_receipt'))
    assert len(caplog.records)==2


def test_concurrent_failures_emit_one_safe_log(caplog):
    with caplog.at_level('WARNING',logger='bobtv.epg.manifest'):
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(api._record_manifest_failure,[sqlite_error(sqlite3.SQLITE_BUSY) for _ in range(64)]))
    assert len(caplog.records)==1
    assert len(api._failure_log_times)==1


def test_real_readonly_lock_failure_then_recovery(tmp_path,monkeypatch,caplog):
    path=tmp_path/'fixture.sqlite3'
    writer=sqlite3.connect(path)
    writer.execute('CREATE TABLE example(value TEXT)')
    writer.commit()
    monkeypatch.setattr(api,'DATABASE',path)
    app=FastAPI()
    app.include_router(api.router)
    client=TestClient(app)
    try:
        writer.execute('BEGIN EXCLUSIVE')
        with caplog.at_level('WARNING',logger='bobtv.epg.manifest'):
            response=client.get('/api/v1/epg/manifest')
        assert response.status_code==503
        assert any('reason=database_busy sqlite_primary_code=5' in record.getMessage() for record in caplog.records)
        writer.rollback()
        assert client.get('/api/v1/epg/manifest').json()=={'schemaVersion':1,'version':None,'channelCount':0}
    finally:
        writer.close()
