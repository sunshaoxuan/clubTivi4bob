"""Validate artifact integrity and distinguish complete files from submission readiness."""
import argparse
import hashlib
import json
from pathlib import Path


def validate(root):
    errors=[]
    metadata=list((root/'store-metadata').glob('*/metadata.json'))
    if len(metadata)!=7:errors.append('Expected seven metadata locales')
    for path in metadata:
        data=json.loads(path.read_text())
        for field,maximum in [('name',30),('subtitle',30),('promotionalText',170),('description',4000),('whatsNew',4000)]:
            if not data.get(field) or len(data[field])>maximum:errors.append(str(path)+': '+field)
        if len(data['keywords'].encode('utf-8'))>100:errors.append(str(path)+': keywords exceed 100 UTF-8 bytes')
    for required in ['BobTV-App-Review-Overview.pdf','readiness.json','sources.json','private/app-review-contact.json','private/account-access.json','privacy-data-map.csv','review/review-notes-en.txt','review/review-notes-zh.txt','review/demo-public-URL-REQUIRED.bobtv','rights/THIRD-PARTY-NOTICES.txt','technical/bundled-privacy-manifests.json']:
        path=root/required
        if not path.is_file() or not path.stat().st_size:errors.append('Missing '+required)
    if (root/'SHA256SUMS.json').exists():
        for relative,expected in json.loads((root/'SHA256SUMS.json').read_text()).items():
            path=root/relative
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:errors.append('Hash mismatch '+relative)
    screens=root/'screenshots/manifest.json'
    if screens.exists():
        from PIL import Image
        data=json.loads(screens.read_text());families=set()
        for item in data['images']:
            path=root/item['file']
            if not path.is_file():errors.append('Missing screenshot '+item['file']);continue
            with Image.open(path) as im:
                if list(im.size)!=item['pixels']:errors.append('Screenshot dimensions differ '+item['file'])
            if item.get('acceptedSizeClass'):families.add(item['family'])
        if not {'iphone','ipad13'}.issubset(families):errors.append('Missing actual required-size screenshot family')
    else:errors.append('Screenshot manifest absent')
    readiness=json.loads((root/'readiness.json').read_text())
    blockers=[x['id'] for x in readiness.get('blockers',[]) if not x.get('resolved')]
    if not readiness.get('readyToSubmit'):blockers.append('READY_FLAG_FALSE')
    return {'filesValid':not errors,'fileErrors':errors,'readyToSubmit':not errors and not blockers,'submissionBlockers':blockers}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('bundle',type=Path);parser.add_argument('--strict',action='store_true');args=parser.parse_args()
    result=validate(args.bundle.resolve());print(json.dumps(result,ensure_ascii=False,indent=2))
    if not result['filesValid'] or args.strict and not result['readyToSubmit']:raise SystemExit(1)


if __name__=='__main__':main()
