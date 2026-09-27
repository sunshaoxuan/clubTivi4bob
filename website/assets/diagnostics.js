document.querySelector('#log-file').addEventListener('change', event => {
  document.querySelector('#selected-file').textContent = event.target.files[0]?.name ?? '未选择文件';
});

document.querySelector('#upload-form').addEventListener('submit', async event => {
  event.preventDefault();
  const file = document.querySelector('#log-file').files[0];
  const status = document.querySelector('#upload-status');
  if (!file || file.size > 1024 * 1024) { status.textContent = '请选择不超过 1 MiB 的日志。'; return; }
  const button = event.currentTarget.querySelector('button'); button.disabled = true; status.textContent = '正在检查日志…';
  try {
    const fields = ['time', 'event', 'source', 'fatal', 'uptimeSeconds', 'rssBytes', 'maxRssBytes', 'platform'];
    const lines = (await file.text()).trim().split(/\r?\n/);
    if (lines.length > 5000) throw new Error('日志条目过多');
    const safe = lines.map(line => {
      const entry = JSON.parse(line);
      if (typeof entry.time !== 'string' || typeof entry.event !== 'string') throw new Error('文件格式不正确');
      return JSON.stringify(Object.fromEntries(fields.filter(key => ['string', 'number', 'boolean'].includes(typeof entry[key])).map(key => [key, entry[key]])));
    }).join('\n') + '\n';
    if (new TextEncoder().encode(safe).length > 1024 * 1024) throw new Error('处理后日志超过 1 MiB');
    status.textContent = '正在上传…';
    const response = await fetch('/api/v1/logs', { method: 'POST', headers: { 'Content-Type': 'application/x-ndjson' }, body: safe });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const result = await response.json();
    status.textContent = `上传完成。诊断编号：${result.id.slice(0, 12)}`;
  } catch (error) { status.textContent = `上传失败（${error.message}）。请检查文件为 JSONL 诊断日志。`; }
  finally { button.disabled = false; }
});
