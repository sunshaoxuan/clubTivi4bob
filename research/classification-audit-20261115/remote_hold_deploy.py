import datetime,fcntl,gzip,hashlib,json,os,pathlib,pwd,sqlite3,subprocess,sys,tempfile
stage=pathlib.Path(sys.argv[1]);plan=json.loads((stage/'hold-deploy-input.json').read_text());site=pathlib.Path('/opt/bobtv/site');data=pathlib.Path('/var/lib/bobtv')
checked=json.loads((stage/'hold-clone-check-result.json').read_text());assert checked['fullInventoryClonePassed'] and checked['allPublicCardsEqualControl'] and checked['sourceCommit']==plan['sourceCommit']
for item in plan['files']:assert hashlib.sha256((stage/item['name']).read_bytes()).hexdigest()==item['sha256'],('stage source drift',item['name'])
for name,digest in plan['baseline'].items():assert hashlib.sha256((site/name).read_bytes()).hexdigest()==digest,('production source drift',name)
units=['bobtv-catalog.service','bobtv-catalog-taxonomy.service','bobtv-catalog-reclassify-20261015.service','bobtv-pending-channel-ai.service','bobtv-task@classification.service']
for unit in units:assert subprocess.run(['systemctl','is-active','--quiet',unit]).returncode!=0,('classification writer running',unit)
def put(path,raw):
 fd,tmp=tempfile.mkstemp(prefix='.market-hold-',dir=path.parent)
 try:
  with os.fdopen(fd,'wb') as f:f.write(raw);f.flush();os.fsync(f.fileno())
  os.chmod(tmp,0o644);os.replace(tmp,path)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');backup=pathlib.Path('/opt/bobtv/backups')/('market-hold-'+now);backup.mkdir(mode=0o700)
with (data/'catalog-process.lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX)
 conn=sqlite3.connect(data/'channel_inventory.sqlite3',timeout=30);conn.row_factory=sqlite3.Row;conn.execute('BEGIN IMMEDIATE')
 old_manifest=(data/'channel-catalog/manifest.json').read_bytes();manifest=json.loads(old_manifest);old_queue=(data/'broadcast-market-review-queue.json').read_bytes();old_payload=json.loads(gzip.decompress((data/'channel-catalog/snapshots'/(manifest['sha256']+'.json.gz')).read_bytes()))
 assert manifest['sha256']==checked['currentSha256'],'public base moved; rerun comparison'
 with sqlite3.connect('file:'+str(stage/'hold-clone-candidate/channel_inventory.sqlite3')+'?mode=ro',uri=True) as reference:
  reference.row_factory=sqlite3.Row;holds=reference.execute('SELECT * FROM catalog_market_review_holds').fetchall();assert len(holds)==130
  for h in holds:
   entity=conn.execute('SELECT * FROM catalog_channels WHERE id=?',(h['channel_id'],)).fetchone();m=json.loads(entity['metadata']);p=json.loads(entity['profile']);fm=json.loads(h['frozen_metadata']);fp=json.loads(h['frozen_profile'])
   assert entity['group_name']==h['frozen_group'] and all(m.get(k)==fm.get(k) for k in ('countryCode','regionCode','categoryId')) and all(p.get(k)==fp.get(k) for k in ('country','region')),('pending inventory moved',h['channel_id'])
 with sqlite3.connect('file:'+str(data/'channel_inventory.sqlite3')+'?mode=ro',uri=True) as src,sqlite3.connect(backup/'channel_inventory.sqlite3') as dest:src.backup(dest)
 (backup/'manifest.json').write_bytes(old_manifest);(backup/'broadcast-market-review-queue.json').write_bytes(old_queue);(backup/'source-plan.json').write_text(json.dumps(plan,indent=2))
 old={};missing=[]
 for item in plan['files']:
  path=site/item['name']
  if path.exists():old[item['name']]=path.read_bytes();(backup/item['name']).write_bytes(old[item['name']])
  else:missing.append(item['name'])
 (backup/'missing-before.json').write_text(json.dumps(missing))
 try:
  for item in plan['files']:put(site/item['name'],(stage/item['name']).read_bytes())
  sys.path[:0]=[str(stage),str(site)]
  from market_review_hold import refresh_holds
  from publish_channel_catalog import publish
  added=refresh_holds(conn,data);assert added==130
  old_payload['version']=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ')
  new_manifest=publish(old_payload,data,market_review_conn=conn)
  # Publication is inside the approval transaction; retain private 0600 files
  # while assigning the three newly replaced outputs to their service reader.
  service_user=pwd.getpwnam('bobtv')
  outputs=[data/'channel-catalog/manifest.json',data/'channel-catalog/snapshots'/(new_manifest['sha256']+'.json.gz'),data/'broadcast-market-review-queue.json']
  for output in outputs:
   os.chown(output,service_user.pw_uid,service_user.pw_gid);os.chmod(output,0o600)
  new_payload=json.loads(gzip.decompress((data/'channel-catalog/snapshots'/(new_manifest['sha256']+'.json.gz')).read_bytes()))
  assert {c['id']:c for c in old_payload['channels']}=={c['id']:c for c in new_payload['channels']},'unexpected public card changes'
  queue=json.loads((data/'broadcast-market-review-queue.json').read_text());assert queue['persistentHoldCount']==130 and queue['reviewFindingCount']==130
  assert conn.execute('PRAGMA quick_check').fetchone()[0]=='ok'
  statuses=dict(conn.execute('SELECT status,count(*) FROM catalog_market_review_holds GROUP BY status').fetchall());route_holds=conn.execute('SELECT count(*) FROM catalog_market_hold_routes').fetchone()[0]
  conn.commit()
 except BaseException:
  conn.rollback();put(data/'channel-catalog/manifest.json',old_manifest);put(data/'broadcast-market-review-queue.json',old_queue)
  for name,raw in old.items():put(site/name,raw)
  for name in missing:
   if (site/name).exists():(site/name).unlink()
  raise
 finally:conn.close()
 user=pwd.getpwnam('bobtv')
 for path in data.glob('channel_inventory.sqlite3*'):os.chown(path,user.pw_uid,user.pw_gid)
 result={'state':'passed','sourceCommit':plan['sourceCommit'],'stagingDirectory':str(stage),'backupDirectory':str(backup),'previousManifest':manifest,'newManifest':new_manifest,'sourceHashesVerified':True,'pendingBaselineNoDrift':True,'pendingCount':130,'heldRouteCount':route_holds,'holdStatuses':statuses,'allPublicChannelCardsUnchanged':True,'channelCount':len(new_payload['channels']),'routeCount':sum(len(c['routes']) for c in new_payload['channels']),'privateClientEdits':0,'epgMappingEdits':0,'classificationServicesDisabled':False}
 (backup/'deployment-result.json').write_text(json.dumps(result,indent=2));(stage/'hold-deployment-result.json').write_text(json.dumps(result,indent=2))
subprocess.run(['systemctl','restart','bobtv.service'],check=True,timeout=45);subprocess.run(['systemctl','is-active','--quiet','bobtv.service'],check=True)
result['serviceRestartedAndActive']=True
for path in [backup/'deployment-result.json',stage/'hold-deployment-result.json']:path.write_text(json.dumps(result,indent=2))
print(json.dumps(result))
