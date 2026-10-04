const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.textContent = ''; }
  append(child) { this.children.push(child); }
  replaceChildren() { this.children = []; }
  setAttribute(name, value) { this[name] = value; }
}

test('A Mac-only release keeps the latest verified Windows installer', async () => {
  const list = new Element('div');
  const releases = [
    {version: 'v1.0.2', platform: 'macOS Intel', filename: 'BobTV-1.0.2+83-macos-x64.dmg'},
    {version: 'v1.0.2', platform: 'macOS Apple Silicon', filename: 'BobTV-1.0.2+83-macos-arm64.dmg'},
    {version: 'v1.0.1', platform: 'Windows x64', filename: 'BobTV-1.0.1+82-windows-x64.zip'},
    {version: 'v1.0.1', platform: 'Windows x64', filename: 'BobTV-1.0.1+82-windows-x64-Setup.exe'},
  ].map(item => ({...item, date: '2026-10-05', size: '60 MB', sha256: 'abc'}));
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../assets/downloads.js'), 'utf8'), {
    document: {querySelector: () => list, createElement: tag => new Element(tag)},
    fetch: async () => ({ok: true, json: async () => ({releases})}),
  });
  await new Promise(resolve => setImmediate(resolve));
  const choices = list.children[0].children[1].children;
  assert.equal(choices.length, 3);
  assert.match(choices[0].href, /Setup\.exe$/);
  assert.match(choices[0]['aria-label'], /v1\.0\.1/);
  assert.match(choices[1]['aria-label'], /v1\.0\.2/);
  assert.match(choices[2]['aria-label'], /v1\.0\.2/);
  assert.equal(list.children[1].children.length, 4);
});
