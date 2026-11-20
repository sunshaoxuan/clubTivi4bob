'use strict';
const $ = id => document.getElementById(id);
let selected = null, offset = 0, generation = 0;
const labels = {login_required:'请先登录',admin_required:'该账号没有管理员权限',invalid_or_expired_code:'验证码错误或已过期',rate_limited:'操作过于频繁，请稍后重试',email_exists:'该邮箱已存在',email_delivery_failed:'邮件暂时发送失败',email_unconfigured:'验证码邮件尚未配置',cannot_remove_own_admin_access:'不能撤销自己的管理员权限',provider_email_immutable:'第三方账号的邮箱不能在这里修改'};
function status(message) { $('status').textContent = message; }
async function api(path, method='GET', body) {
 const r = await fetch('/api/v1/'+path,{method,credentials:'same-origin',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,cache:'no-store'});
 const data = await r.json(); if(!r.ok) throw Error(labels[data.detail] || (typeof data.detail==='string'?data.detail:'请求失败')); return data;
}
async function showAccount(){
 const u=await api('account/me');
 if(!u.admin) { await api('account/logout','POST'); throw Error('该账号没有管理员权限'); }
 $('login').hidden=true; $('management').hidden=false; $('logout').hidden=false; status(u.email); await load();
}
async function load(){
 const data=await api('admin/users?q='+encodeURIComponent($('query').value)+'&offset='+offset);
 $('users').replaceChildren();
 for(const u of data.users){
  const tr=document.createElement('tr');
  for(const value of [u.email,u.name,u.verified?'通过':'未验证',u.disabled?'禁用':'正常',u.admin?'管理员':'用户']){const td=document.createElement('td');td.textContent=value;tr.append(td);}
  const td=document.createElement('td'), b=document.createElement('button');b.textContent='编辑';b.onclick=()=>edit(u);td.append(b);tr.append(td);$('users').append(tr);
 }
 $('previous').disabled=offset===0; $('next').disabled=!data.hasMore;
}
function edit(user){selected=user; $('edit-title').textContent=user?'编辑用户':'创建用户';$('edit-email').value=user?.email||'';$('edit-name').value=user?.name||'';$('edit-verified').checked=!!user?.verified;$('edit-disabled').checked=!!user?.disabled;$('editor').showModal();}
$('send').onclick=async()=>{if(!$('email').reportValidity())return;const b=$('send');b.disabled=true;try{await api('account/email/code','POST',{email:$('email').value});status('验证码已发送，十分钟内有效。');setTimeout(()=>b.disabled=false,60000);}catch(e){status(e.message);b.disabled=false;}};
$('login-form').onsubmit=async e=>{e.preventDefault();try{await api('account/email/verify','POST',{email:$('email').value,code:$('code').value});await showAccount();}catch(e){status(e.message);}};
$('logout').onclick=async()=>{try{await api('account/logout','POST');location.reload();}catch(e){status(e.message);}};
$('search-form').onsubmit=async e=>{e.preventDefault();offset=0;try{await load();}catch(e){status(e.message);}};
$('new').onclick=()=>edit(null);$('cancel').onclick=()=>$('editor').close();
$('previous').onclick=async()=>{offset=Math.max(0,offset-50);try{await load();}catch(e){status(e.message);}};
$('next').onclick=async()=>{offset+=50;try{await load();}catch(e){status(e.message);}};
$('edit-form').onsubmit=async e=>{e.preventDefault();const b=e.submitter;b.disabled=true;try{await api('admin/users'+(selected?'/'+selected.id:''),selected?'PATCH':'POST',{email:$('edit-email').value,name:$('edit-name').value,verified:$('edit-verified').checked,disabled:$('edit-disabled').checked});$('editor').close();status('已保存');await load();}catch(e){status(e.message);}finally{b.disabled=false;}};
async function providerLogin(provider){
 // A client-held proof binds the one-time login ticket to this browser.
 const raw=crypto.getRandomValues(new Uint8Array(32));const proof=btoa(String.fromCharCode(...raw)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
 const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(proof));const challenge=btoa(String.fromCharCode(...new Uint8Array(hash))).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
 const win=window.open('about:blank','_blank'); if(!win)throw Error('请允许登录窗口');
 let start;try{start=await api('account/oauth/start','POST',{provider,proof:challenge});win.location=start.url;}catch(e){win.close();throw e;}
 const run=++generation;
 for(let i=0;i<100&&run===generation;i++){await new Promise(r=>setTimeout(r,3000));const result=await api('account/oauth/poll','POST',{ticket:start.ticket,proof});if(!result.pending){win.close();await showAccount();return;}}
 throw Error('登录已过期，请重试');
}
(async()=>{try{const c=await api('account/config');for(const p of ['google','apple'])if(c[p]){const b=document.createElement('button');b.textContent=p==='google'?'使用 Google 登录':'使用 Apple 登录';b.onclick=()=>providerLogin(p).catch(e=>status(e.message));$('providers').append(b);}try{await showAccount();}catch(e){if(e.message!=='请先登录')status(e.message);}}catch(e){status(e.message);}})();
