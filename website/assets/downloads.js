const list = document.querySelector('#release-list');
const messageNode = document.querySelector('#site-messages');
const copy = messageNode ? JSON.parse(messageNode.textContent) : {};
const text = (key, fallback) => copy[key] || fallback;
const families = [
  { id: 'windows', title: 'Windows', mark: '⊞', description: 'Setup / ZIP', cpus: [
    { id: 'x64', label: 'Intel / AMD · x64', platform: 'Windows x64' },
    { id: 'arm64', label: 'ARM64 · Surface', platform: 'Windows ARM64' },
  ] },
  { id: 'macos', title: 'macOS', mark: '⌘', description: 'DMG', cpus: [
    { id: 'arm64', label: 'Apple Silicon', platform: 'macOS Apple Silicon' },
    { id: 'x64', label: 'Intel · x64', platform: 'macOS Intel' },
  ] },
  { id: 'android', title: 'Android', mark: '▣', description: 'APK · Android 7+', cpus: [
    { id: 'arm64', label: 'ARM64', platform: 'Android ARM64' },
    { id: 'arm', label: 'ARM32', platform: 'Android ARM32' },
    { id: 'x64', label: 'x64', platform: 'Android x64' },
  ] },
];
function element(tag, className, value) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (value) node.textContent = value;
  return node;
}
function downloadLink(release, label, secondary = false) {
  const link = element('a', secondary ? 'release-secondary' : 'release-download');
  link.href = `/downloads/${encodeURIComponent(release.filename)}`;
  if (globalThis.BobTVResources) {
    globalThis.BobTVResources.resolve(link.href).then(url => { link.href = url; }).catch(() => {});
  }
  link.setAttribute('download', release.filename);
  link.setAttribute('aria-label', `${text('download', '下载')} ${release.platform} ${release.version}, ${release.size}`);
  link.append(element('span', '', label));
  link.append(element('span', '', secondary ? '↗' : '↓'));
  return link;
}
(globalThis.BobTVResources ? globalThis.BobTVResources.fetch('/releases.json') : fetch('/releases.json'))
  .then(response => {
    if (!response.ok) throw new Error('Release list unavailable');
    return response.json();
  })
  .then(({ releases }) => {
    list.replaceChildren();
    if (!Array.isArray(releases) || !releases.length) {
      list.textContent = text('empty', '安装包准备中，请稍后查看。');
      return;
    }
    const latest = releases[0];
    const panel = element('div', 'release-panel');
    const version = element('div', 'release-version');
    version.append(element('span', 'release-version-label', text('current', '最新发布')));
    version.append(element('strong', 'release-version-number', latest.version));
    version.append(element('span', 'release-version-date', text('published', '发布于 {date}').replace('{date}', latest.date)));
    version.append(element('span', 'release-version-caption', text('cpu_note', '先选择系统，再选择 CPU。')));
    panel.append(version);
    const choices = element('div', 'release-choices');
    const selected = [];
    for (const family of families) {
      const variants = family.cpus.map(cpu => {
        const candidates = releases.filter(item => item.platform === cpu.platform);
        const newest = candidates.filter(item => item.version === candidates[0]?.version);
        return { ...cpu, files: newest, release: newest.find(item => item.filename.endsWith('-Setup.exe')) || newest[0] };
      });
      if (!variants.some(cpu => cpu.release)) continue;
      const card = element('article', 'release-family');
      card.setAttribute('data-platform', family.id);
      const header = element('div', 'release-family-heading');
      header.append(element('span', 'release-choice-icon', family.mark));
      const heading = element('div');
      heading.append(element('h3', 'release-family-title', family.title));
      heading.append(element('span', 'release-choice-detail', family.description));
      header.append(heading);
      card.append(header);
      const tabs = element('div', 'release-cpu-tabs');
      tabs.setAttribute('role', 'tablist');
      tabs.setAttribute('aria-label', `${family.title} CPU`);
      const content = element('div', 'release-cpu-content');
      content.id = `download-${family.id}`;
      content.setAttribute('role', 'tabpanel');
      const buttons = [];
      function activate(variant) {
        for (const [button, cpu] of buttons) {
          button.className = `release-cpu-tab${cpu === variant ? ' active' : ''}`;
          button.setAttribute('aria-selected', String(cpu === variant));
        }
        content.replaceChildren();
        const release = variant.release;
        const format = release.filename.endsWith('-Setup.exe') ? text('exe', 'EXE 安装程序') : family.description;
        content.append(element('p', 'release-selected-version', `${release.version} · ${format} · ${release.size}`));
        content.append(downloadLink(release, text('download_package', '下载安装包')));
        const portable = variant.files.find(item => item.filename.endsWith('.zip'));
        if (portable && portable !== release) content.append(downloadLink(portable, text('portable_download', '下载 ZIP 便携包'), true));
        if (family.id === 'windows' && variant.id === 'arm64') {
          content.append(element('p', 'release-family-note', text('windows_arm64_note', 'ARM64 原生包已通过构建与架构校验；Surface 实机播放与更新仍待验证。')));
        }
      }
      for (const cpu of variants) {
        if (!cpu.release) {
          if (family.id === 'windows' && cpu.id === 'arm64') {
            const pending = element('span', 'release-cpu-pending', 'ARM64');
            pending.setAttribute('title', text('surface_pending', 'Surface ARM 原生版待编译验证'));
            pending.append(element('small', '', text('pending', '准备中')));
            tabs.append(pending);
          }
          continue;
        }
        selected.push(...cpu.files);
        const button = element('button', 'release-cpu-tab', cpu.label);
        button.type = 'button';
        button.setAttribute('role', 'tab');
        button.setAttribute('aria-controls', content.id);
        button.setAttribute('data-cpu', cpu.id);
        button.addEventListener('click', () => activate(cpu));
        buttons.push([button, cpu]);
        tabs.append(button);
      }
      card.append(tabs);
      card.append(content);
      card.append(element('p', 'release-family-note', text(`${family.id}_note`, '')));
      activate(variants.find(cpu => cpu.release));
      choices.append(card);
    }
    if (!choices.children.length) {
      list.textContent = text('empty', '安装包准备中，请稍后查看。');
      return;
    }
    panel.append(choices);
    list.append(panel);
    const checksums = element('details', 'release-checksums');
    checksums.append(element('summary', '', text('checksum', '查看 SHA-256 校验值')));
    for (const release of selected) {
      const row = element('div', 'checksum-row');
      row.append(element('span', '', `${release.platform} · ${release.filename.endsWith('.zip') ? 'ZIP' : release.filename.endsWith('.apk') ? 'APK' : release.filename.endsWith('.dmg') ? 'DMG' : 'Setup'}`));
      row.append(element('code', '', release.sha256));
      checksums.append(row);
    }
    list.append(checksums);
  })
  .catch(() => { list.textContent = text('release_error', '版本信息暂时不可用，请稍后再试。'); });
