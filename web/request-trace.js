const safeField = value => String(value ?? '').replace(/[^A-Za-z0-9 ._()+-]/g, '').slice(0, 64);

export function browserContext(build, agent = globalThis.navigator?.userAgent ?? '') {
  const device = agent.match(/iPhone|iPad|Android/)?.[0] ?? (/Mobile/.test(agent) ? 'phone' : 'desktop');
  const mobile = device !== 'desktop';
  const os = agent.match(/(?:Android|Windows NT|(?:CPU (?:iPhone )?OS)|Mac OS X)[ /][\d._]+/)?.[0]
    ?? (/Linux/.test(agent) ? 'Linux' : 'unknown');
  const browser = agent.match(/(?:EdgA?|EdgiOS|OPR|FxiOS)\/[\d.]+/)?.[0]
    ?? agent.match(/(?:Firefox|CriOS|Chrome)\/[\d.]+/)?.[0]
    ?? (agent.includes('Safari/') ? 'Safari ' + (agent.match(/Version\/([\d.]+)/)?.[1] ?? '') : 'unknown');
  return {platform: mobile ? 'mobile-web' : 'desktop-web', device, os, version: browser.replace('/', ' '), build};
}

export function startRequestTrace(path, context = {}) {
  const bytes = new Uint8Array(16);
  // This random value correlates logs. It grants no access.
  if (globalThis.crypto?.getRandomValues) globalThis.crypto.getRandomValues(bytes);
  else for (let i = 0; i < bytes.length; i++) bytes[i] = Math.floor(Math.random() * 256);
  const requestId = Array.from(bytes, n => n.toString(16).padStart(2, '0')).join('');
  const client = Object.fromEntries(['platform', 'device', 'os', 'version', 'build']
    .map(key => [key, safeField(context[key])]).filter(([, value]) => value));
  const headers = {'X-Request-Id': requestId, 'X-Stack-Client': JSON.stringify(client)};
  const started = Date.now();
  let finished = false;
  const details = {request_id: requestId, route: path, client};
  console.debug('Stack request started', details);
  return {
    headers,
    apply(xhr) {
      for (const [name, value] of Object.entries(headers)) xhr.setRequestHeader(name, value);
    },
    finish(response, outcome = 'response') {
      if (finished) return;
      finished = true;
      const status = response?.status || 0;
      const ray = (response?.headers?.get?.('CF-Ray') ?? response?.getResponseHeader?.('CF-Ray')) || '';
      const cfRay = /^[a-f0-9]{16,32}(?:-[A-Z]{3})?$/.test(ray) ? ray : undefined;
      const log = status >= 400 || outcome !== 'response' ? console.warn : console.debug;
      log('Stack request finished', {...details, status, outcome, cf_ray: cfRay, elapsed_ms: Date.now() - started});
    },
    fail(error, response) {
      this.finish(response, error.name === 'AbortError' || error.name === 'TimeoutError' ? 'interrupted' : 'failed');
      error.requestId = requestId;
      return error;
    },
  };
}
