"""Read and checksum EPG snapshots from both public nodes for client replay."""
import argparse,base64,gzip,hashlib,json,time,urllib.request
from pathlib import Path
NODES=['https://bobtv.briconbric.com','https://cndrp.com/bobtv']
def get(url):
    with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'BobTV-EPG-Validator/1.0'}),timeout=20) as r:return r.read(32*1024*1024)
def main():
    p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
    manifests=[json.loads(get(n+'/api/v1/epg/manifest')) for n in NODES]
    assert manifests[0]==manifests[1],'public manifests disagree'
    manifest=manifests[0];snapshots=[get(n+manifest['snapshotUrl']) for n in NODES]
    assert snapshots[0]==snapshots[1]
    assert hashlib.sha256(snapshots[0]).hexdigest()==manifest['sha256']
    payload=json.loads(gzip.decompress(snapshots[0]));assert payload['version']==manifest['version']
    catalog_manifest=json.loads(get(NODES[0]+'/api/v1/channel-catalog/manifest'))
    raw=get(NODES[0]+catalog_manifest['snapshotUrl']);assert hashlib.sha256(raw).hexdigest()==catalog_manifest['sha256']
    catalog=json.loads(gzip.decompress(raw));categories={r['id']:r for r in catalog['categories']}
    def group(c):
        parts=[];cid=c['categoryId']
        while cid is not None:
            row=categories[cid];parts.append(row['name']);cid=row['parentId']
        return '/'.join(reversed(parts))
    ids={c['id'] for c in payload['channels']};targets=[{'channel':c,'group':group(c)} for c in catalog['channels'] if c['id'] in ids]
    assert len(targets)==manifest['channelCount']
    capture={'verifiedAtUtc':int(time.time()),'nodes':NODES,'manifest':manifest,
        'snapshotBase64':base64.b64encode(snapshots[0]).decode(),'catalogTargets':targets,'catalogManifest':catalog_manifest,'catalogVersion':catalog['version']}
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(capture,ensure_ascii=False))
    print(json.dumps({'version':manifest['version'],'channels':manifest['channelCount'],'programmes':manifest['programmeCount'],'nodesVerified':2}))
if __name__=='__main__':main()
