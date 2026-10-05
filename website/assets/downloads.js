const list = document.querySelector('#release-list');
const messages = JSON.parse(document.querySelector('#site-messages').textContent);
const message = (key, values = {}) => messages[key].replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
const platforms = [
  { name: 'Windows x64', system: 'WINDOWS', label: messages.windows, format: messages.zip, mark: '⊞' },
  { name: 'macOS Intel', system: 'MACOS', label: messages.intel, format: messages.dmg, mark: '⌘' },
  { name: 'macOS Apple Silicon', system: 'MACOS', label: messages.silicon, format: messages.dmg, mark: '⌘' },
];

function element(tag, className, value) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (value) node.textContent = value;
  return node;
}

fetch('/releases.json')
  .then(response => {
    if (!response.ok) throw new Error('Release list unavailable');
    return response.json();
  })
  .then(({ releases }) => {
    list.replaceChildren();
    if (!Array.isArray(releases) || !releases.length) {
      list.textContent = messages.empty;
      return;
    }
    const latest = releases[0];
    const panel = element('div', 'release-panel');
    const version = element('div', 'release-version');
    version.append(element('span', 'release-version-label', messages.current));
    version.append(element('strong', 'release-version-number', latest.version));
    version.append(element('span', 'release-version-date', message('published', { date: latest.date })));
    version.append(element('span', 'release-version-caption', messages.version_note));
    panel.append(version);
    const choices = element('div', 'release-choices');
    const selected = [];
    for (const platform of platforms) {
      const candidates = releases.filter(item => item.platform === platform.name);
      const newest = candidates.filter(item => item.version === candidates[0]?.version);
      const release = newest.find(item => item.filename.endsWith('-Setup.exe')) || newest[0];
      if (!release) continue;
      selected.push(release);
      const link = element('a', 'release-choice');
      link.href = '/downloads/' + encodeURIComponent(release.filename);
      link.setAttribute('download', release.filename);
      link.setAttribute('aria-label', message('download_label', { platform: platform.label, version: release.version, size: release.size }));
      link.append(element('span', 'release-choice-icon', platform.mark));
      link.append(element('span', 'release-choice-system', platform.system));
      link.append(element('strong', 'release-choice-title', platform.label));
      const format = release.filename.endsWith('-Setup.exe') ? messages.exe : platform.format;
      link.append(element('span', 'release-choice-detail', [release.version, format, release.size].join(' · ')));
      link.append(element('span', 'release-choice-action', messages.download + ' ↗'));
      choices.append(link);
    }
    if (!choices.children.length) {
      list.textContent = messages.empty;
      return;
    }
    panel.append(choices);
    list.append(panel);
    const checksums = element('details', 'release-checksums');
    checksums.append(element('summary', '', messages.checksum));
    for (const release of selected) {
      const row = element('div', 'checksum-row');
      row.append(element('span', '', release.platform || release.filename));
      row.append(element('code', '', release.sha256));
      checksums.append(row);
    }
    list.append(checksums);
  })
  .catch(() => { list.textContent = messages.release_error; });
