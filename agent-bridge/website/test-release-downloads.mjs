import test from 'node:test';
import assert from 'node:assert/strict';
import { releaseDownloads } from './release-downloads.js';
const manifest = { version:'0.1.6', notes:'release', platforms:{'darwin-aarch64':{url:'https://download.classktv.com/releases/arclink-v0.1.6/ArcLink-macos-arm64.app.tar.gz',signature:'sig'},'darwin-x86_64':{url:'https://download.classktv.com/releases/arclink-v0.1.6/ArcLink-macos-x64.app.tar.gz',signature:'sig'}}};
test('valid manifest derives both DMG links',()=>assert.deepEqual(Object.keys(releaseDownloads(manifest,'0.1.5').downloads),['arm64','x64']));
test('stale or untrusted manifests are rejected',()=>{assert.throws(()=>releaseDownloads({...manifest,version:'0.1.4'},'0.1.5'));assert.throws(()=>releaseDownloads({...manifest,platforms:{...manifest.platforms,'darwin-aarch64':{...manifest.platforms['darwin-aarch64'],url:'https://evil.example/a'}}},'0.1.5'));});

import { refreshDownloads } from './release-downloads.js';
function page() {
  const versions = [{dataset:{releaseVersion:'0.1.5'},textContent:'v0.1.5'}];
  const buttons = Object.fromEntries(['arm64','x64'].map(arch => {
    const label = {textContent:'fallback 123 MB'};
    return [arch,{href:'fallback-'+arch,querySelector:()=>label,label}];
  }));
  return {versions,buttons,querySelectorAll:()=>versions,querySelector:selector=>buttons[selector.match(/"(.*?)"/)[1]]};
}
test('successful fetch updates version, both links and stale size labels',async()=>{
  const root=page();
  assert.equal(await refreshDownloads(root,async(url,options)=>{assert.equal(options.credentials,'omit');return {ok:true,json:async()=>manifest};}),true);
  assert.equal(root.versions[0].textContent,'v0.1.6');
  for(const arch of ['arm64','x64']) {assert.ok(root.buttons[arch].href.endsWith(`${arch}.dmg`));assert.ok(!root.buttons[arch].label.textContent.includes('MB'));}
});
test('HTTP, JSON, network, CORS and validation failures retain every fallback',async()=>{
  for(const fetcher of [async()=>{throw new TypeError('CORS');},async()=>({ok:false}),async()=>({ok:true,json:async()=>{throw Error('json');}}),async()=>({ok:true,json:async()=>({...manifest,platforms:{}})})]) {
    const root=page();assert.equal(await refreshDownloads(root,fetcher),false);
    assert.equal(root.versions[0].textContent,'v0.1.5');
    assert.equal(root.buttons.arm64.href,'fallback-arm64');assert.equal(root.buttons.x64.href,'fallback-x64');
  }
});
test('timeout aborts a pending request and preserves fallback',async()=>{
  const root=page();
  assert.equal(await refreshDownloads(root,async(_,options)=>new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(Error('aborted')))),5),false);
  assert.equal(root.buttons.arm64.href,'fallback-arm64');
});
test('missing signature, malformed version and missing platform fail validation',()=>{
  for (const change of [m=>m.version='01.1.6',m=>m.platforms['darwin-aarch64'].signature='',m=>delete m.platforms['darwin-x86_64']]) {
    const candidate=structuredClone(manifest);change(candidate);assert.throws(()=>releaseDownloads(candidate,'0.1.5'));
  }
});
test('production page selects the same-origin manifest proxy', async()=>{
  const root=page();root.documentElement={dataset:{releaseManifest:'/latest.json'}};
  assert.equal(await refreshDownloads(root,async(url)=>{assert.equal(url,'/latest.json');return {ok:true,json:async()=>manifest};}),true);
});
