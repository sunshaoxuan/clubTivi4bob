const messages = JSON.parse(document.querySelector('#site-messages').textContent);
const message = (key, values = {}) => messages[key].replace(/\{(\w+)\}/g, (_, name) => String(values[name] ?? ''));
document.querySelector('#log-file').addEventListener('change', event => {
  document.querySelector('#selected-file').textContent = event.target.files[0]?.name ?? messages.no_file;
});

document.querySelector('#upload-form').addEventListener('submit', async event => {
  event.preventDefault();
  const file = document.querySelector('#log-file').files[0];
  const status = document.querySelector('#upload-status');
  if (!file || file.size > 1024 * 1024) { status.textContent = messages.file_limit; return; }
  const button = event.currentTarget.querySelector('button');
  button.disabled = true;
  status.textContent = messages.checking;
  try {
    const fields = ['time', 'event', 'source', 'fatal', 'uptimeSeconds', 'rssBytes', 'maxRssBytes', 'platform'];
    const lines = (await file.text()).trim().split(/\r?\n/);
    if (lines.length > 5000) throw new Error(messages.entries);
    const safe = lines.map(line => {
      let entry;
      try { entry = JSON.parse(line); } catch { throw new Error(messages.invalid); }
      if (!entry || typeof entry !== 'object' || Array.isArray(entry) || typeof entry.time !== 'string' || typeof entry.event !== 'string') throw new Error(messages.invalid);
      return JSON.stringify(Object.fromEntries(fields.filter(key => ['string', 'number', 'boolean'].includes(typeof entry[key])).map(key => [key, entry[key]])));
    }).join('\n') + '\n';
    if (new TextEncoder().encode(safe).length > 1024 * 1024) throw new Error(messages.processed_limit);
    status.textContent = messages.uploading;
    const response = await fetch('/api/v1/logs', { method: 'POST', headers: { 'Content-Type': 'application/x-ndjson' }, body: safe });
    if (!response.ok) throw new Error('HTTP ' + response.status);
    const result = await response.json();
    status.textContent = message('success', { id: result.id.slice(0, 12) });
  } catch (error) { status.textContent = message('failure', { error: error.message }); }
  finally { button.disabled = false; }
});
