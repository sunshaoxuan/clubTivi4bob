import struct
import zipfile
import json
import sys
from pathlib import Path
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
sys.path.insert(0, str(Path(__file__).parents[1]))
import mirror_releases
import update_delivery

def elf(machine):
    header=bytearray(20);header[:4]=b'\x7fELF';header[4]=2;header[5]=1
    struct.pack_into('<H',header,18,machine)
    return header

def pe(machine):
    header=bytearray(256);header[:2]=b'MZ';struct.pack_into('<I',header,60,128)
    header[128:132]=b'PE\0\0';struct.pack_into('<H',header,132,machine)
    return header

def test_apk_architectures_are_checked(tmp_path):
    for platform,abi,machine in [('android-arm','armeabi-v7a',40),('android-arm64','arm64-v8a',183),('android-x64','x86_64',62)]:
        apk=tmp_path/(platform+'.apk')
        with zipfile.ZipFile(apk,'w') as package:
            package.writestr('AndroidManifest.xml',b'manifest');package.writestr('classes.dex',b'dex')
            package.writestr(f'lib/{abi}/libflutter.so',elf(machine))
        mirror_releases._inspect_update_archive(apk,platform)
    with zipfile.ZipFile(apk,'w') as package:
        package.writestr('AndroidManifest.xml',b'manifest');package.writestr('classes.dex',b'dex')
        package.writestr('lib/x86_64/libflutter.so',elf(183))
    with pytest.raises(ValueError,match='architecture'):
        mirror_releases._inspect_update_archive(apk,'android-x64')

def test_arm64_windows_never_accepts_x64_dll(tmp_path):
    path=tmp_path/'arm64.zip'
    for machine,valid in [(0xaa64,True),(0x8664,False)]:
        with zipfile.ZipFile(path,'w') as package:
            package.writestr('BobTV/BobTV.exe',pe(0xaa64));package.writestr('BobTV/data/app.so',b'AOT')
            package.writestr('BobTV/flutter_windows.dll',pe(machine))
        if valid: mirror_releases._inspect_update_archive(path,'windows-arm64')
        else:
            with pytest.raises(ValueError,match='architecture'):
                mirror_releases._inspect_update_archive(path,'windows-arm64')

def test_apk_delivery_requires_approval(tmp_path,monkeypatch):
    monkeypatch.setattr(update_delivery,'DATA',tmp_path)
    app=FastAPI();app.include_router(update_delivery.router);client=TestClient(app)
    name='BobTV-1.1.0+93-android-arm64.apk'
    files=tmp_path/'updates/files';files.mkdir(parents=True);(files/name).write_bytes(b'APK')
    assert client.get('/updates/files/'+name).status_code==404
    (tmp_path/'updates/approved.json').write_text(json.dumps({name:'a'*64}))
    response=client.get('/updates/files/'+name)
    assert response.status_code==200
    assert response.headers['content-type']=='application/vnd.android.package-archive'
    assert client.get('/updates/android-arm64/latest.json').status_code==404
