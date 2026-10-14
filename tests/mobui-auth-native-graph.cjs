const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),dir=path.join(root,'.jac/mobui-ios-export/_expo/static/js/ios'),entries=[];
for(const name of fs.readdirSync(dir).filter(n=>n.endsWith('.map'))){const map=JSON.parse(fs.readFileSync(path.join(dir,name)));map.sources.forEach((source,i)=>entries.push([source.replaceAll('\\','/'),map.sourcesContent?.[i]]));}
for(const name of ['auth-session.js','auth-google.js','auth-platform.js'])assert.ok(entries.some(([source])=>source.endsWith('/mobile/'+name)),name+' absent from native bundle');
assert.ok(!entries.some(([source])=>/auth-platform\.web|fixtures\/mobui-auth-platform/.test(source)),'Mock browser authentication in native bundle');
// Metro omits JSON modules from source maps. Check staged mode and the actual
// Hermes string table for the configured test origin, in addition to JS sources.
const config=JSON.parse(fs.readFileSync(path.join(root,'.jac/mobile-rn/jac-src/mobile/auth-config.json')));assert.equal(config.mode,'google-test');assert.equal(config.data,'live');assert.equal(config.origin,new URL(process.env.STACK_API_URL||process.env.STACK_AUTH_API_URL).origin);
assert.ok(fs.readdirSync(dir).filter(n=>n.endsWith('.hbc')||n.endsWith('.js')).some(n=>fs.readFileSync(path.join(dir,n)).includes(Buffer.from(config.origin))),'Account origin absent from native bundle');
assert.ok(entries.some(([source,text])=>source.endsWith('/mobile/device.js')&&text.includes('authCalls')),'Authentication facade absent');
console.log('PASS iOS source graph contains real-auth mode, existing Google protocol, SecureStore adapter, and account feature facade; no browser auth fixture.');
