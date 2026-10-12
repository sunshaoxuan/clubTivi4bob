const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../assets/resources.js'), 'utf8');
const probeBody = Uint8Array.from({length:65536}, (_, i) => (i * 73 + (i >> 8) * 19) & 255);
function setup(fastRelay, failure = false) {
  let time = 0;
  const seen = [];
  const context = {URL, Uint8Array, AbortController, Date, setTimeout, clearTimeout,
    performance:{now:()=>time},
    fetch:async(url, options={})=>{
      seen.push({url, method:options.method || 'GET', body:options.body});
      const relay = url.includes('cndrp.com');
      if(url.endsWith('/probe')) {
        if (relay === fastRelay) {time += 10;} else {await new Promise(r=>setImmediate(r));time += 100;}
        return {ok:true,headers:{get:key=>key==='x-bobtv-node'?(relay?'cndrp':'origin'):'bobtv-resource-v1'},arrayBuffer:async()=>probeBody.buffer};
      }
      if(failure && relay) throw new Error('disconnected');
      return {status:200,ok:true};
    }};
  vm.runInNewContext(source, context);
  return {router:context.BobTVResources,seen};
}
test('browser chooses faster node and shares probes across links',async()=>{
  const {router,seen}=setup(true);
  const urls=await Promise.all([router.resolve('/releases.json'),router.resolve('/downloads/BobTV-test.zip')]);
  assert.equal(urls[0],'https://cndrp.com/bobtv/releases.json');
  assert.equal(urls[1],'https://cndrp.com/bobtv/downloads/BobTV-test.zip');
  assert.equal(seen.length,2);
});
test('faster origin remains selected',async()=>{
  const {router}=setup(false);
  assert.equal(await router.resolve('/releases.json'),'https://bobtv.briconbric.com/releases.json');
});
test('video, external destinations and embedded credentials are rejected',async()=>{
  const {router,seen}=setup(true);
  for(const value of ['/api/v1/egress/resource?kind=media&url=x','https://github.com/a',
      'https://user:pass@bobtv.briconbric.com/release.json']) await assert.rejects(router.resolve(value));
  assert.equal(seen.length,0);
});
test('failed reads fall back, failed uploads are never replayed',async()=>{
  for(const method of ['GET','POST']) {
    const {router,seen}=setup(true,true);
    const result=router.fetch('/api/v1/logs',{method,body:method==='POST'?'private-log':undefined});
    if(method==='POST') await assert.rejects(result); else await result;
    assert.equal(seen.filter(item=>!item.url.endsWith('/probe')).length,method==='POST'?1:2);
  }
});
