"""Detect drift between checked-in Dart inputs and the current Python emitter."""
import base64
import gzip
import hashlib
import json
from pathlib import Path

from epg_contract_fixture import build_contract

FIXTURE=Path(__file__).parents[2]/'test/fixtures/server_epg_contract.json'


def normalized(version):
    raw=base64.b64decode(version['compressedBase64'],validate=True)
    manifest=version['manifest']
    assert len(raw)==manifest['compressedBytes']
    assert hashlib.sha256(raw).hexdigest()==manifest['sha256']
    assert manifest['snapshotUrl']=='/api/v1/epg/snapshots/'+manifest['sha256']+'.json.gz'
    # gzip's platform header/compressor can vary; compare actual JSON and the
    # non-transport manifest fields rather than assuming identical gzip bytes.
    stable={key:value for key,value in manifest.items() if key not in
        ('compressedBytes','sha256','snapshotUrl')}
    return {'manifest':stable,'payload':json.loads(gzip.decompress(raw)),
            'checkedAtUtc':version['checkedAtUtc'],'expectedTitles':version['expectedTitles']}


def test_fixture_matches_current_server_serializer_and_two_atomic_activations():
    checked=json.loads(FIXTURE.read_text())
    generated=build_contract()
    assert checked['fixtureOnly'] is True and checked['productionPublications']==0
    assert generated['networkRequests']==0
    assert generated['simulatedNodeSnapshotChecks']==4
    assert generated['temporaryDatabasePublications']==2
    assert generated['unchangedPublicationReused'] is True
    assert checked['catalogIdentity']==generated['catalogIdentity']
    assert [normalized(v) for v in checked['versions']]==[normalized(v) for v in generated['versions']]
    assert checked['versions'][0]['manifest']['version']!=checked['versions'][1]['manifest']['version']
