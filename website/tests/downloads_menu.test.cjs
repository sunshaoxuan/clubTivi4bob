const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');const path=require('node:path');const vm=require('node:vm');
class Element {
 constructor(tag){this.tag=tag;this.children=[];this.textContent='';this.listeners={};}
 append(child){this.children.push(child);}
 replaceChildren(){this.children=[];}
 setAttribute(name,value){this[name]=value;}
 addEventListener(name,action){this.listeners[name]=action;}
}
const walk=node=>[node,...node.children.flatMap(walk)];
const links=node=>walk(node).filter(item=>item.tag==='a');
const button=(node,cpu)=>walk(node).find(item=>item.tag==='button'&&item['data-cpu']===cpu);
async function render(items){
 const list=new Element('div');
 const releases=items.map(item=>({...item,date:'2026-10-12',size:'43 MB',sha256:'abc'}));
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../assets/downloads.js'),'utf8'),{
  document:{querySelector:selector=>selector==='#release-list'?list:null,createElement:tag=>new Element(tag)},
  fetch:async()=>({ok:true,json:async()=>({releases})}),
 });
 await new Promise(resolve=>setImmediate(resolve));
 return list;
}
test('Each OS is one column; Mac CPU changes never replace the Windows download',async()=>{
 const list=await render([
  {version:'v1.0.2',platform:'macOS Intel',filename:'BobTV-1.0.2+83-macos-x64.dmg'},
  {version:'v1.0.2',platform:'macOS Apple Silicon',filename:'BobTV-1.0.2+83-macos-arm64.dmg'},
  {version:'v1.0.1',platform:'Windows x64',filename:'BobTV-1.0.1+82-windows-x64.zip'},
  {version:'v1.0.1',platform:'Windows x64',filename:'BobTV-1.0.1+82-windows-x64-Setup.exe'},
 ]);
 const groups=list.children[0].children[1].children;
 assert.equal(groups.length,2);
 const [windows,mac]=groups;
 assert.equal(windows['data-platform'],'windows');assert.equal(mac['data-platform'],'macos');
 assert.match(links(windows)[0].href,/Setup\.exe$/);
 assert.match(links(windows)[1].href,/windows-x64\.zip$/);
 assert.match(links(mac)[0].href,/macos-arm64\.dmg$/);
 button(mac,'x64').listeners.click();
 assert.match(links(mac)[0].href,/macos-x64\.dmg$/);
 assert.equal(button(mac,'x64')['aria-selected'],'true');
 assert.equal(button(mac,'arm64')['aria-selected'],'false');
 assert.match(links(windows)[0]['aria-label'],/v1\.0\.1/);
 assert.ok(walk(windows).some(item=>item.className==='release-family-note release-platform-pending' && item.textContent.includes('v1.0.1')));
 assert.ok(!walk(mac).some(item=>item.className==='release-family-note release-platform-pending'));
 assert.equal(button(windows,'arm64'),undefined);
 assert.equal(list.children[1].children.length,5);
});
test('Android CPU choices stay in one column and display only real files',async()=>{
 const list=await render([
  {version:'v1.1.0',platform:'Android ARM64',filename:'BobTV-1.1.0+93-android-arm64.apk'},
  {version:'v1.1.0',platform:'Android ARM32',filename:'BobTV-1.1.0+93-android-arm.apk'},
 ]);
 const groups=list.children[0].children[1].children;assert.equal(groups.length,1);
 const android=groups[0];assert.equal(android['data-platform'],'android');
 assert.match(links(android)[0].href,/android-arm64\.apk$/);
 button(android,'arm').listeners.click();assert.match(links(android)[0].href,/android-arm\.apk$/);
 assert.equal(button(android,'x64'),undefined);
});
test('A real ARM64 Windows asset enables its CPU choice',async()=>{
 const list=await render([{version:'v1.1.0',platform:'Windows ARM64',filename:'BobTV-1.1.0+93-windows-arm64-Setup.exe'}]);
 const windows=list.children[0].children[1].children[0];
 assert.equal(button(windows,'x64'),undefined);
 assert.match(links(windows)[0].href,/windows-arm64-Setup\.exe$/);
 assert.ok(walk(windows).some(item=>item.textContent.includes('Surface 实机')));
});
