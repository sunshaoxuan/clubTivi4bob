import datetime,fcntl,gzip,hashlib,json,os,pathlib,pwd,shutil,sqlite3,subprocess,sys
stage=pathlib.Path(sys.argv[1]);data=pathlib.Path('/var/lib/bobtv');live=pathlib.Path('/opt/bobtv/site');sys.path.insert(0,str(live))
from catalog_taxonomy import classified_path
from country_names import normalize_country_name
source_plan=json.loads((stage/'hold-deploy-input.json').read_text())
for item in source_plan['files']:assert hashlib.sha256((stage/item['name']).read_bytes()).hexdigest()==item['sha256']
BASE='7c2612972eaa2ee4cee1c11fe50f31e6c32fb36fd3bf2857028d94369c8c0ec2'
def payload_for(sha):return json.loads(gzip.decompress((data/'channel-catalog/snapshots'/(sha+'.json.gz')).read_bytes()))
def paths(payload):
 cats={c['id']:c for c in payload['categories']}
 def path(cid):
  c=cats[cid];return (path(c['parentId']) if c['parentId'] else [])+[c['name']]
 return {c['id']:{'countryCode':c.get('countryCode'),'regionCode':c.get('regionCode'),'path':path(c['categoryId'])} for c in payload['channels']}
uid=pwd.getpwnam('bobtv').pw_uid;gid=pwd.getpwnam('bobtv').pw_gid
with (data/'catalog-process.lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 raw=(data/'channel-catalog/manifest.json').read_bytes();manifest=json.loads(raw);packed=(data/'channel-catalog/snapshots'/(manifest['sha256']+'.json.gz')).read_bytes();assert hashlib.sha256(packed).hexdigest()==manifest['sha256']
 queue_raw=(data/'broadcast-market-review-queue.json').read_bytes();queue=json.loads(queue_raw);ids={f['channelId'] for f in queue['reviewFindings']};assert len(ids)==130
 baseline=paths(payload_for(BASE));current=paths(payload_for(manifest['sha256']));assert all(baseline[i]==current[i] for i in ids),'public pending geography drift'
 drift=[]
 with sqlite3.connect('file:'+str(data/'channel_inventory.sqlite3')+'?mode=ro',uri=True) as conn:
  conn.row_factory=sqlite3.Row
  for identity in ids:
   r=conn.execute('SELECT * FROM catalog_channels WHERE id=?',(identity,)).fetchone();m=json.loads(r['metadata']);p=json.loads(r['profile'])
   parts=r['group_name'].split(' / ')
   if len(parts)>1 and parts[0]=='国际':parts[1]=normalize_country_name(parts[1])
   geo={'countryCode':m.get('countryCode'),'regionCode':m.get('regionCode'),'path':classified_path(parts,m)}
   if geo!=baseline[identity]:drift.append({'id':identity,'expected':baseline[identity],'actual':geo})
 assert not drift,('pending inventory geography drift',drift)
 result={'state':'passed','baselineSha256':BASE,'currentSha256':manifest['sha256'],'pendingCount':len(ids),'publicAndInventoryGeographyUnchanged':True,'drift':drift,'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 (stage/'pending-baseline-check.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
 for lane in (['candidate'] if len(sys.argv)>2 and sys.argv[2]=='candidate-only' else ['control','candidate']):
  folder=stage/('hold-clone-'+lane);(folder/'channel-catalog/snapshots').mkdir(parents=True,exist_ok=True)
  (folder/'channel-catalog/manifest.json').write_bytes(raw);(folder/'channel-catalog/snapshots'/(manifest['sha256']+'.json.gz')).write_bytes(packed);(folder/'broadcast-market-review-queue.json').write_bytes(queue_raw)
  with sqlite3.connect('file:'+str(data/'channel_inventory.sqlite3')+'?mode=ro',uri=True) as source,sqlite3.connect(folder/'channel_inventory.sqlite3') as dest:source.backup(dest)
  if (data/'channel-reference.json').exists():shutil.copyfile(data/'channel-reference.json',folder/'channel-reference.json')
  for root,dirs,files in os.walk(folder):
   os.chown(root,uid,gid)
   for name in files:os.chown(pathlib.Path(root)/name,uid,gid)
program='''import json,gzip,pathlib,os,sys,sqlite3
from process_channel_inventory import process
folder=pathlib.Path(os.environ['BOBTV_DATA_DIR'])
result=process(folder,limit=0)
manifest=json.loads((folder/'channel-catalog/manifest.json').read_text())
payload=json.loads(gzip.decompress((folder/'channel-catalog/snapshots'/(manifest['sha256']+'.json.gz')).read_bytes()))
(folder/'result-payload.json').write_text(json.dumps(payload,ensure_ascii=False))
if sys.argv[1]=='candidate':
 from catalog_inventory import database
 from market_review_hold import preserve_public_geography
 with database(folder) as conn:
  holds=conn.execute('SELECT * FROM catalog_market_review_holds').fetchall();assert len(holds)==130
  row=holds[0];identity=row['channel_id'];before=dict(conn.execute('SELECT * FROM catalog_channels WHERE id=?',(identity,)).fetchone())
  conn.execute('SAVEPOINT probe');conn.execute("UPDATE catalog_channels SET metadata=json_set(metadata,'$.countryCode','ZZ','$.categoryId','wrong'),profile=json_set(profile,'$.country','ZZ'),group_name='wrong' WHERE id=?",(identity,))
  after=dict(conn.execute('SELECT * FROM catalog_channels WHERE id=?',(identity,)).fetchone());assert before['group_name']==after['group_name'] and json.loads(before['metadata'])==json.loads(after['metadata']) and json.loads(before['profile'])==json.loads(after['profile'])
  member=conn.execute('SELECT digest FROM catalog_market_hold_routes WHERE channel_id=?',(identity,)).fetchone();conn.execute("UPDATE catalog_channel_routes SET channel_id='wrong-owner' WHERE digest=?",(member['digest'],));assert conn.execute('SELECT channel_id FROM catalog_channel_routes WHERE digest=?',(member['digest'],)).fetchone()[0]==identity
  conn.execute('ROLLBACK TO probe');conn.execute('RELEASE probe')
  assert conn.execute('SELECT count(*) FROM catalog_market_hold_routes').fetchone()[0]>=130
 print('candidate durable SQL guards passed',flush=True)
print(json.dumps({'lane':sys.argv[1],'process':result,'channels':len(payload['channels']),'routes':sum(len(c['routes']) for c in payload['channels'])}),flush=True)
'''
for lane in (['candidate'] if len(sys.argv)>2 and sys.argv[2]=='candidate-only' else ['control','candidate']):
 paths_value=str(live) if lane=='control' else str(stage)+':'+str(live)
 r=subprocess.run(['runuser','-u','bobtv','--','env','BOBTV_DATA_DIR='+str(stage/('hold-clone-'+lane)),'PYTHONPATH='+paths_value,'/opt/bobtv/venv/bin/python','-c',program,lane],text=True,capture_output=True,timeout=240)
 print(r.stdout,flush=True)
 if r.returncode:print(r.stderr[-5500:]);raise SystemExit(r.returncode)
a=json.loads((stage/'hold-clone-control/result-payload.json').read_text());b=json.loads((stage/'hold-clone-candidate/result-payload.json').read_text());aa={c['id']:c for c in a['channels']};bb={c['id']:c for c in b['channels']};assert aa==bb,'full candidate versus control card drift'
assert len(bb)==9098 and sum(len(c['routes']) for c in bb.values())==10127
for identity in ['channel-b842f9cdd43743693f77fc81','channel-9294d4892ed3478727d98e6d']:assert bb[identity]['countryCode']=='GB'
assert all(paths(b)[i]==baseline[i] for i in ids)
assert source_plan==json.loads((stage/'hold-deploy-input.json').read_text()),'source changed during clone run'
result.update(sourceCommit=source_plan['sourceCommit'],fullInventoryClonePassed=True,allPublicCardsEqualControl=True,channelCount=len(bb),routeCount=sum(len(c['routes']) for c in bb.values()),heldCount=130,durableGuardProbePassed=True)
(stage/'hold-clone-check-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
