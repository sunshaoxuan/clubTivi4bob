const list = document.querySelector('#release-list');
fetch('/releases.json').then(r => { if (!r.ok) throw new Error(); return r.json(); }).then(({ releases }) => {
  list.replaceChildren();
  if (!releases.length) { list.textContent = '安装包准备中，请稍后查看。'; return; }
  for (const release of releases) {
    const row = document.createElement('div'); row.className = 'release-row';
    const info = document.createElement('div');
    const title = document.createElement('strong'); title.textContent = release.version;
    const meta = document.createElement('small'); meta.textContent = `${release.date} · ${release.size} · SHA-256 ${release.sha256}`;
    info.append(title, meta);
    const link = document.createElement('a'); link.className = 'button primary'; link.textContent = '下载 Windows x64'; link.href = `/downloads/${encodeURIComponent(release.filename)}`; link.setAttribute('download', release.filename);
    row.append(info, link); list.append(row);
  }
}).catch(() => { list.textContent = '版本信息暂时不可用。'; });
