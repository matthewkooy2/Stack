// Read-only confirmation of the exact uploaded beta. Never prints tokens, keys or API response bodies.
const {createPrivateKey, sign} = require('node:crypto');
const fs = require('node:fs');
async function main(env = process.env) {
  const version = `${1000 + Number(env.GITHUB_RUN_NUMBER)}.${Number(env.GITHUB_RUN_ATTEMPT)}`;
  const key = createPrivateKey(fs.readFileSync(env.ASC_AUTH_KEY_PATH));
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  async function get(route) {
    const now = Math.floor(Date.now() / 1000);
    const payload = `${encode({alg:'ES256',kid:env.ASC_KEY_ID,typ:'JWT'})}.${encode({iss:env.ASC_ISSUER_ID,iat:now,exp:now+300,aud:'appstoreconnect-v1'})}`;
    const signature = sign('sha256',Buffer.from(payload),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
    const response = await fetch(`https://api.appstoreconnect.apple.com/v1/${route}`,{
      headers:{Authorization:`Bearer ${payload}.${signature}`},signal:AbortSignal.timeout(30000)
    });
    if (!response.ok) throw new Error(`Apple processing lookup returned HTTP ${response.status}.`);
    return response.json();
  }
  const apps = await get('apps?filter[bundleId]=com.matthewkooy.stack&limit=2');
  if (apps.data?.length !== 1) throw new Error('Cannot identify the existing Stack app.');
  let reported = '';
  for (let attempt=0;attempt<60;attempt++) {
    const result = await get(`builds?filter[app]=${encodeURIComponent(apps.data[0].id)}&filter[version]=${encodeURIComponent(version)}&include=preReleaseVersion&limit=5`);
    const build = result.data?.find(item => item.attributes?.version === version && result.included?.some(
      included => included.id === item.relationships?.preReleaseVersion?.data?.id && included.attributes?.version === '0.2.0'));
    const state = build?.attributes?.processingState || 'NOT_VISIBLE';
    if (state !== reported) { console.log(`Swift beta 0.2.0 (${version}) Apple processing: ${state}.`); reported = state; }
    if (state === 'VALID') { console.log('Exact native beta processed successfully. Phone installation remains a tester action.'); return; }
    if (['FAILED','INVALID'].includes(state)) throw new Error(`Apple processing failed: ${state}.`);
    await new Promise(resolve => setTimeout(resolve,10000));
  }
  console.log('Upload completed, but Apple processing remains pending after this bounded check.');
}
if (require.main === module) main().catch(error => {
  const safe = /^(Apple processing|Cannot identify)/.test(error.message);
  console.error(safe ? error.message : 'Apple processing lookup failed; check the existing credentials and connectivity.');
  process.exitCode = 1;
});
