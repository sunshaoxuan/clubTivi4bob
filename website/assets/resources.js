/* Shared browser resource transport. Video is deliberately excluded. */
(() => {
  const origin = 'https://bobtv.briconbric.com';
  const relay = 'https://cndrp.com/bobtv';
  let selected = origin, expires = 0, pending;
  async function probe(base) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 3000);
    const start = performance.now();
    try {
      const response = await fetch(base + '/api/v1/resource-node/probe', {
        cache: 'no-store', credentials: 'omit', signal: controller.signal,
      });
      if (!response.ok || response.headers.get('x-bobtv-probe') !== 'bobtv-resource-v1' ||
          response.headers.get('x-bobtv-node') !== (base === relay ? 'cndrp' : 'origin')) return null;
      const body = new Uint8Array(await response.arrayBuffer());
      if (body.length !== 65536 || body.some((value, i) => value !== ((i * 73 + (i >> 8) * 19) & 255))) return null;
      return performance.now() - start;
    } catch (_) { return null; }
    finally { clearTimeout(timer); }
  }
  async function compare() {
    const [primary, edge] = await Promise.all([probe(origin), probe(relay)]);
    selected = edge !== null && (primary === null || edge < primary) ? relay : origin;
    expires = Date.now() + (primary === null && edge === null ? 30000 : 600000);
  }
  async function resolve(path) {
    const canonical = new URL(path, origin);
    if (canonical.origin !== origin || canonical.username || canonical.password ||
        !(/^\/(api\/v1\/|updates\/|downloads\/|assets\/)/.test(canonical.pathname) || canonical.pathname === '/releases.json')) {
      throw new Error('Unsupported resource destination');
    }
    if (canonical.pathname === '/api/v1/egress/resource' && canonical.searchParams.get('kind') === 'media') {
      throw new Error('Video cannot use resource relay');
    }
    if (Date.now() >= expires) {
      pending ||= compare().finally(() => { pending = null; });
      await pending;
    }
    return selected + canonical.pathname + canonical.search;
  }
  async function resourceFetch(path, options = {}) {
    const target = await resolve(path);
    const method = (options.method || 'GET').toUpperCase();
    const readOnly = method === 'GET' || method === 'HEAD';
    let response;
    try {
      response = await fetch(target, { ...options, credentials: 'omit' });
      if (![502, 503, 504].includes(response.status)) return response;
    } catch (error) {
      selected = target.startsWith(relay + '/') ? origin : relay;
      expires = Date.now() + 30000;
      if (!readOnly) throw error; // A sent upload must never be blindly replayed.
      return fetch(await resolve(path), { ...options, credentials: 'omit' });
    }
    selected = target.startsWith(relay + '/') ? origin : relay;
    expires = Date.now() + 30000;
    return readOnly ? fetch(await resolve(path), { ...options, credentials: 'omit' }) : response;
  }
  globalThis.BobTVResources = { resolve, fetch: resourceFetch, node: () => selected };
})();
