"""Read-only validation of an actual iOS archive, without uploading it."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path


def check(root):
    errors=[]
    if not root.is_dir() or root.suffix!='.xcarchive':
        return {'validDistributionArchive':False,'errors':['An actual .xcarchive directory is required; simulator .app is not accepted']}
    apps=list((root/'Products/Applications').glob('*.app'))
    if len(apps)!=1:return {'validDistributionArchive':False,'errors':['Expected one archived iOS application']}
    app=apps[0];info=plistlib.loads((app/'Info.plist').read_bytes());binary=app/info['CFBundleExecutable']
    if info.get('DTPlatformName')!='iphoneos':errors.append('Must target physical iOS, not Simulator')
    r=subprocess.run(['lipo','-archs',str(binary)],capture_output=True,text=True)
    arch=r.stdout.strip().split()
    if 'arm64' not in arch or 'x86_64' in arch:errors.append('Expected iOS arm64 without simulator x86_64')
    r=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True)
    if r.returncode:errors.append('Code signature verification failed')
    r=subprocess.run(['codesign','-d','--entitlements','-','--xml',str(app)],capture_output=True)
    blob=r.stdout
    if b'<?xml' not in blob:blob=r.stderr
    ent={}
    if b'<?xml' in blob:
        try:ent=plistlib.loads(blob[blob.index(b'<?xml'):])
        except plistlib.InvalidFileException:errors.append('Entitlements could not be parsed')
    else:errors.append('No inspectable signing entitlements')
    if ent.get('get-task-allow'):errors.append('Debug get-task-allow remains enabled')
    if not ent.get('application-identifier') or not ent.get('com.apple.developer.team-identifier'):errors.append('Missing actual team and application signing identifiers')
    if not (app/'embedded.mobileprovision').exists():errors.append('Distribution provisioning profile absent')
    if not list((root/'dSYMs').glob('*.dSYM')):errors.append('dSYMs missing')
    if not (app/'PrivacyInfo.xcprivacy').exists():errors.append('Root app privacy manifest requires confirmation')
    return {'validDistributionArchive':not errors,'bundleId':info.get('CFBundleIdentifier'),'version':info.get('CFBundleShortVersionString'),'build':info.get('CFBundleVersion'),'architectures':arch,'errors':errors,'remaining':'App Store Connect processing, SDK signatures, privacy report, entitlements, receipts and operational review access still require verification'}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('archive',type=Path);args=parser.parse_args();result=check(args.archive.resolve());print(json.dumps(result,indent=2))
    if not result['validDistributionArchive']:raise SystemExit(1)


if __name__=='__main__':main()
