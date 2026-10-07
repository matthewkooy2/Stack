const {createPrivateKey, sign} = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

async function preflight(env = process.env, request = fetch) {
  for (const name of ['STACK_API_URL', 'APPLE_TEAM_ID', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY']) {
    if (!env[name]) throw new Error(`Missing Actions configuration: ${name}`);
  }
  const api = new URL(env.STACK_API_URL);
  if (api.protocol !== 'https:' || api.username || api.password) throw new Error('STACK_API_URL must be an HTTPS origin without credentials.');
  if (!/^[A-Z0-9]{10}$/.test(env.APPLE_TEAM_ID)) throw new Error('APPLE_TEAM_ID must be a 10-character Team ID.');
  const now = Math.floor(Date.now() / 1000);
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const payload = `${encode({alg:'ES256', kid:env.ASC_KEY_ID, typ:'JWT'})}.${encode({iss:env.ASC_ISSUER_ID, iat:now, exp:now+300, aud:'appstoreconnect-v1'})}`;
  const key = createPrivateKey(env.ASC_PRIVATE_KEY);
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails.namedCurve !== 'prime256v1') throw new Error('App Store Connect requires a P-256 private key.');
  const signature = sign('sha256', Buffer.from(payload), {key, dsaEncoding:'ieee-p1363'}).toString('base64url');
  const get = async route => {
    const response = await request(`https://api.appstoreconnect.apple.com/v1/${route}`, {
      headers:{Authorization:`Bearer ${payload}.${signature}`}, signal:AbortSignal.timeout(30000),
    });
    if (!response.ok) throw new Error(`App Store Connect preflight returned HTTP ${response.status}.`);
    return response.json();
  };
  const apps = await get('apps?filter[bundleId]=com.matthewkooy.stack&limit=2');
  if (apps.data?.length !== 1) throw new Error('Expected one App Store Connect app for com.matthewkooy.stack.');
  const config = fs.readFileSync(path.join(__dirname, '../../native/app.config.js'), 'utf8');
  const version = config.match(/version:\s*'([^']+)'/)?.[1];
  if (!version) throw new Error('Cannot determine the configured marketing version.');
  const versions = await get(`apps/${encodeURIComponent(apps.data[0].id)}/appStoreVersions?filter[platform]=IOS&filter[versionString]=${encodeURIComponent(version)}&limit=2`);
  if (!versions.data?.some(v => v.attributes?.versionString === version && v.attributes?.platform === 'IOS')) {
    throw new Error(`Create the iOS ${version} version record in App Store Connect before enabling uploads.`);
  }
  console.log(`App Store Connect credentials and iOS ${version} version record verified.`);
}
module.exports = {preflight};
if (require.main === module) preflight().catch(error => {
  // Do not print network bodies, tokens, or private key parser diagnostics.
  const safe = /^(Missing Actions|STACK_API_URL|APPLE_TEAM_ID|App Store Connect|Expected one|Cannot determine|Create the iOS)/.test(error.message);
  console.error(safe ? error.message : 'App Store Connect preflight failed; check the configured key and connectivity.');
  process.exitCode = 1;
});
