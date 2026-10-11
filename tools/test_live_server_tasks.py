"""Verify the public task queue and result API without catalog mutations."""
import json
import time
import urllib.request

origin='https://bobtv.briconbric.com/api/v1/server-tasks'
def request(path='', data=None):
    req=urllib.request.Request(origin+path,data=None if data is None else json.dumps(data).encode(),headers={'Content-Type':'application/json','User-Agent':'BobTV/1.0.5 QA'})
    with urllib.request.urlopen(req,timeout=15) as response:
        if response.url!=req.full_url:raise ValueError('Unexpected task redirect')
        return json.load(response)

status=request('/status')
assert status['execution']=='server' and status['workerAvailable'] and status['aiAvailable']
value=request(data={'kind':'category','inputs':[{'name':'CCTV-1 综合','group':'中国 / 央视','tvgId':'CCTV1'}]})
deadline=time.monotonic()+180
while value['state'] in ('queued','running') and time.monotonic()<deadline:
    time.sleep(10)
    value=request('/'+value['id'])
assert value['state']=='done', value.get('errorCode')
assert any(item.get('category')=='央视' for item in value['items'])
print(json.dumps({'serverExecution':True,'workerAvailable':True,'aiAvailable':True,'publicTaskRoundtrip':'passed','category':'央视'},ensure_ascii=False))
