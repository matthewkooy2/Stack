const {test} = require('node:test');
const assert = require('node:assert/strict');
const {generateKeyPairSync, verify, createPublicKey} = require('node:crypto');
const {preflight} = require('../scripts/ci/asc-preflight.cjs');
const {privateKey} = generateKeyPairSync('ec', {namedCurve:'prime256v1'});
const env = {STACK_API_URL:'https://stack.example.com', APPLE_TEAM_ID:'ABCDE12345', ASC_KEY_ID:'FIXTURE', ASC_ISSUER_ID:'fixture', ASC_PRIVATE_KEY:privateKey.export({type:'pkcs8',format:'pem'})};
const app = {data:[{id:'fixture'}]};
const version = {data:[{attributes:{versionString:'0.1.0',platform:'IOS'}}]};
test('preflight signs a valid token and verifies the configured app/version', async () => {
  const urls=[];
  await preflight(env, async (url, options) => {
    urls.push(url);
    const [header,payload,signature] = options.headers.Authorization.slice(7).split('.');
    assert(verify('sha256', Buffer.from(`${header}.${payload}`), {key:createPublicKey(privateKey),dsaEncoding:'ieee-p1363'}, Buffer.from(signature,'base64url')));
    assert.equal(JSON.parse(Buffer.from(payload,'base64url')).aud,'appstoreconnect-v1');
    return {ok:true,json:async()=>urls.length===1?app:version};
  });
  assert.match(urls[0], /filter\[bundleId\]=com.matthewkooy.stack/);
  assert.match(urls[1], /filter\[versionString\]=0.1.0/);
});
test('missing secret stops before network access', async () => {
  await assert.rejects(preflight({...env,ASC_PRIVATE_KEY:''}, () => assert.fail('network called')), /ASC_PRIVATE_KEY/);
});
test('missing version blocks uploads', async () => {
  let calls=0;
  await assert.rejects(preflight(env, async()=>({ok:true,json:async()=>++calls===1?app:{data:[]}})), /Create the iOS 0.1.0/);
});
test('Apple authentication failure is reported without response contents', async () => {
  await assert.rejects(preflight(env, async()=>({ok:false,status:401,json:()=>assert.fail('body read')})), /HTTP 401/);
});
