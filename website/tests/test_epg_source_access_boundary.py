"""Shared access-denial boundary, using only authored fixtures and fake I/O."""
import pytest

from test_epg_ingest import NOW, SOURCE, xml
import epg_ingest as epg


@pytest.mark.parametrize('format_', ['xmltv', 'tvmaze-json', 'cctv-json'])
@pytest.mark.parametrize('code', ['http_401', 'http_403'])
def test_all_formats_pause_access_denials_across_timer_restarts(tmp_path, format_, code):
    source={**SOURCE, 'format':format_}
    calls=[]
    def denied(_):
        calls.append(1)
        raise epg.EpgError(code)
    first=epg.probe_batch(tmp_path,[source],NOW,denied)
    receipt=first['sources'][0]
    assert first['attemptedSources']==1 and calls==[1]
    assert receipt['state']=='manual_review' and receipt['last_error']==code
    for now in (receipt['next_retry']+1,NOW+30*86400):
        after=epg.probe_batch(tmp_path,[source],now,
            lambda _:pytest.fail('a paused source cannot retry automatically'))
        assert after['attemptedSources']==0 and after['sources']==first['sources']
    with epg.database(tmp_path) as conn:
        assert conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0]==2


@pytest.mark.parametrize('code', ['http_401', 'http_403'])
def test_legacy_denial_is_paused_once_without_request_or_evidence_loss(tmp_path,code):
    epg.probe_batch(tmp_path,[SOURCE],NOW,lambda _:(xml(),{}))
    with epg.database(tmp_path) as conn:
        conn.execute("UPDATE source_health SET state='failed',failures=2,last_failure=?,last_error=?,next_retry=?",
            (NOW+10,code,NOW+20))
        conn.commit()
        before=dict(conn.execute('SELECT * FROM source_health').fetchone())
        identities=[tuple(row) for row in conn.execute('SELECT * FROM source_identities')]
        count=conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0]
    result=epg.probe_batch(tmp_path,[SOURCE],NOW+30,
        lambda _:pytest.fail('legacy denial needs review before any new request'))
    after=result['sources'][0]
    assert result['attemptedSources']==0
    assert after=={**before,'state':'manual_review'}
    epg.probe_batch(tmp_path,[SOURCE],NOW+86400,
        lambda _:pytest.fail('manual review remains persistent'))
    with epg.database(tmp_path) as conn:
        assert [tuple(row) for row in conn.execute('SELECT * FROM source_identities')]==identities
        assert conn.execute('SELECT count(*) FROM probe_audit').fetchone()[0]==count+1
        event=dict(conn.execute('SELECT * FROM probe_audit ORDER BY id DESC LIMIT 1').fetchone())
        assert event['state']=='manual_review' and event['error_code']==code
        assert event['sha256'] is None and event['quality'] is None


def test_new_denial_retains_last_good_identity_and_allows_other_source(tmp_path):
    source={**SOURCE,'refreshSeconds':900}
    original=epg.probe_batch(tmp_path,[source],NOW,lambda _:(xml(),{}))['sources'][0]
    with epg.database(tmp_path) as conn:
        identities=[tuple(row) for row in conn.execute('SELECT * FROM source_identities')]
    other={**SOURCE,'id':'other','url':'https://other.example.org/guide.xml'}
    def fetch(source):
        if source['id']==SOURCE['id']:
            raise epg.EpgError('http_403')
        return xml(),{}
    result=epg.probe_batch(tmp_path,[source,other],NOW+900,fetch,batch_size=2)
    rows={row['id']:row for row in result['sources']}
    denied=rows[SOURCE['id']]
    assert result['attemptedSources']==2 and denied['state']=='manual_review'
    for key in ('last_success','content_sha256','last_good_quality'):
        assert denied[key]==original[key]
    assert rows['other']['state']=='healthy'
    with epg.database(tmp_path) as conn:
        assert [tuple(row) for row in conn.execute('SELECT * FROM source_identities WHERE source_id=?',
            (SOURCE['id'],))]==identities


@pytest.mark.parametrize('code',['http_429','http_500','http_502','network_failure'])
def test_transient_errors_keep_backoff_and_recovery(tmp_path,code):
    def failed(_):
        raise epg.EpgError(code,retry_after=900)
    first=epg.probe_batch(tmp_path,[SOURCE],NOW,failed)['sources'][0]
    assert first['state']=='failed' and first['next_retry']>=NOW+900
    assert epg.probe_batch(tmp_path,[SOURCE],first['next_retry']-1,
        lambda _:pytest.fail('respect retry backoff'))['attemptedSources']==0
    recovered=epg.probe_batch(tmp_path,[SOURCE],first['next_retry'],lambda _:(xml(),{}))['sources'][0]
    assert recovered['state']=='healthy' and recovered['failures']==0


def test_non_auth_manual_review_is_never_overridden(tmp_path):
    epg.probe_batch(tmp_path,[SOURCE],NOW,lambda _:(xml(),{}))
    with epg.database(tmp_path) as conn:
        conn.execute("UPDATE source_health SET state='manual_review',last_error='operator_hold'")
        conn.commit()
        before=dict(conn.execute('SELECT * FROM source_health').fetchone())
    result=epg.probe_batch(tmp_path,[SOURCE],NOW+86400,
        lambda _:pytest.fail('respect operator review hold'))
    assert result['attemptedSources']==0 and result['sources']==[before]
