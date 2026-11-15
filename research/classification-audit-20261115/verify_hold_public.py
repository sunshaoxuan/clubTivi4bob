import datetime,gzip,hashlib,json,pathlib,urllib.request
folder=pathlib.Path(__file__).parent
receipt=json.loads((folder/'hold-deployment-result.json').read_text());queue=json.loads((folder/'broadcast-market-review-queue.json').read_text())
def get(url):
 with urllib.request.urlopen(url,timeout=35) as response:return response.read()
results=[]
for base in ['https://bobtv.briconbric.com','https://cndrp.com/bobtv']:
 result={'base':base,'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 try:
  manifest=json.loads(get(base+'/api/v1/channel-catalog/manifest'));raw=get(base+manifest['snapshotUrl']);assert hashlib.sha256(raw).hexdigest()==manifest['sha256'];assert len(raw)==manifest['compressedBytes'];assert manifest['sha256']==receipt['newManifest']['sha256']
  payload=json.loads(gzip.decompress(raw));original=json.loads(gzip.decompress(get(base+'/api/v1/channel-catalog/snapshots/'+receipt['previousManifest']['sha256']+'.json.gz')))
  a={c['id']:c for c in original['channels']};b={c['id']:c for c in payload['channels']};assert a==b
  assert len(b)==9098 and sum(len(c['routes']) for c in b.values())==10127
  cats={c['id']:c for c in payload['categories']}
  def path(cid):
   c=cats[cid];return (path(c['parentId']) if c['parentId'] else [])+[c['name']]
  targets=[{'id':c['id'],'name':c['name'],'countryCode':c['countryCode'],'path':path(c['categoryId']),'epgId':c['epgId'],'routes':len(c['routes'])} for c in b.values() if c['id'] in ['channel-b842f9cdd43743693f77fc81','channel-9294d4892ed3478727d98e6d']]
  assert all(c['countryCode']=='GB' and c['path']==['国际','英国','电视','电影'] for c in targets)
  assert len(queue['reviewFindings'])==130 and queue['persistentHoldCount']==130
  assert all(a[f['channelId']]==b[f['channelId']] for f in queue['reviewFindings'])
  result.update(status='verified',manifest=manifest,sha256Verified=True,compressedBytesVerified=True,allPublicChannelCardsUnchanged=True,pending130Unchanged=True,targets=targets)
 except Exception as exc:result.update(status='unavailable',errorType=type(exc).__name__,error=str(exc))
 results.append(result)
(folder/'hold-public-verification.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print(json.dumps(results,ensure_ascii=False))
assert any(r['status']=='verified' for r in results)
