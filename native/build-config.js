// Shared by Expo configuration and Jac's generated native entry.
const fs = require('fs');
const path = require('path');

function buildSettings(env = process.env, projectDir = __dirname) {
  const release = env.STACK_BUILD_MODE === 'release';
  let api = env.STACK_API_URL;
  if (!api && !release) {
    const hostFile = path.join(projectDir, 'stack-host.json');
    api = fs.existsSync(hostFile) ? JSON.parse(fs.readFileSync(hostFile, 'utf8')).apiBaseUrl : 'http://localhost:8000';
  }
  if (!api || typeof api !== 'string') throw new Error('A release build requires an explicit STACK_API_URL=https://your-host.');
  let url;
  try { url = new URL(api); } catch { throw new Error('STACK_API_URL must be a valid API origin.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('STACK_API_URL must be an HTTP(S) origin without credentials, path, query, or fragment.');
  }
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, '').replace(/\.$/, '');
  const local = host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') ||
    host === '::' || host === '::1' || host.startsWith('::ffff:') || host.startsWith('fe80:') || /^(fc|fd)[0-9a-f]{2}:/.test(host) ||
    /^(0|10|127)\./.test(host) || /^192\.168\./.test(host) || /^169\.254\./.test(host) ||
    /^172\.(1[6-9]|2[0-9]|3[01])\./.test(host);
  if (release && (url.protocol !== 'https:' || local || !host.includes('.'))) {
    throw new Error('Release STACK_API_URL must use HTTPS and a reachable hostname, not a local development address.');
  }
  const pushEnabled = env.STACK_PUSH_ENABLED === '1';
  const pushEnvironment = env.STACK_PUSH_ENVIRONMENT || 'development';
  if (pushEnabled && !['development', 'production'].includes(pushEnvironment)) {
    throw new Error('STACK_PUSH_ENVIRONMENT must be development or production.');
  }
  if (pushEnabled && !env.STACK_EAS_PROJECT_ID) throw new Error('Remote push requires STACK_EAS_PROJECT_ID and Apple push provisioning.');
  return {release, apiBaseUrl: url.origin, pushEnabled, pushEnvironment};
}

function writeSettings(output, env = process.env) {
  const settings = buildSettings(env, output);
  fs.mkdirSync(output, {recursive: true});
  fs.writeFileSync(path.join(output, 'stack-host.json'), JSON.stringify({apiBaseUrl: settings.apiBaseUrl}) + '\n');
  fs.writeFileSync(path.join(output, '__jacApiBase.js'), 'globalThis.__JAC_API_BASE_URL__ = ' + JSON.stringify(settings.apiBaseUrl) + ';\n');
  return settings;
}

module.exports = {buildSettings, writeSettings};
if (require.main === module) {
  try {
    if (process.argv[2] === '--write' && process.argv[3]) writeSettings(path.resolve(process.argv[3]));
    else if (process.argv[2] === '--check') buildSettings(process.env, path.resolve(process.argv[3] || __dirname));
    else throw new Error('Usage: node native/build-config.js --check [output] | --write output');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
