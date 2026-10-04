const list = document.querySelector('#release-list');
const platforms = [
  { name: 'Windows x64', system: 'WINDOWS', label: 'Windows 版', format: 'ZIP 便携包', mark: '⊞' },
  { name: 'macOS Intel', system: 'MACOS', label: 'Intel Mac 版', format: 'DMG 安装映像', mark: '⌘' },
  { name: 'macOS Apple Silicon', system: 'MACOS', label: 'Apple Silicon 版', format: 'DMG 安装映像', mark: '⌘' },
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
      list.textContent = '安装包准备中，请稍后查看。';
      return;
    }

    const latest = releases[0];
    const panel = element('div', 'release-panel');
    const version = element('div', 'release-version');
    version.append(element('span', 'release-version-label', '当前版本'));
    version.append(element('strong', 'release-version-number', latest.version));
    version.append(element('span', 'release-version-date', `发布于 ${latest.date}`));
    version.append(element('span', 'release-version-caption', '各平台最新安装包，下载按钮标明版本。'));
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
      link.href = `/downloads/${encodeURIComponent(release.filename)}`;
      link.setAttribute('download', release.filename);
      link.setAttribute('aria-label', `下载 ${platform.label} ${release.version}，${release.size}`);
      link.append(element('span', 'release-choice-icon', platform.mark));
      link.append(element('span', 'release-choice-system', platform.system));
      link.append(element('strong', 'release-choice-title', platform.label));
      const format = release.filename.endsWith('-Setup.exe') ? 'EXE 安装程序' : platform.format;
      link.append(element('span', 'release-choice-detail', `${release.version} · ${format} · ${release.size}`));
      link.append(element('span', 'release-choice-action', '立即下载 ↗'));
      choices.append(link);
    }
    if (!choices.children.length) {
      list.textContent = '当前版本的安装包准备中，请稍后查看。';
      return;
    }
    panel.append(choices);
    list.append(panel);

    const checksums = element('details', 'release-checksums');
    checksums.append(element('summary', '', '查看安装包 SHA-256 校验值'));
    for (const release of selected) {
      const row = element('div', 'checksum-row');
      row.append(element('span', '', release.platform || release.filename));
      row.append(element('code', '', release.sha256));
      checksums.append(row);
    }
    list.append(checksums);
  })
  .catch(() => { list.textContent = '版本信息暂时不可用，请稍后再试。'; });
