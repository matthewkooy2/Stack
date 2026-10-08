const assert=require('node:assert/strict'),path=require('path');
const esbuild=require('../.jac/mobui-tools/node_modules/esbuild');
const code=esbuild.buildSync({entryPoints:[path.join(__dirname,'../mobile/auth-session.js')],bundle:true,platform:'node',format:'cjs',write:false}).outputFiles[0].text;
const mod={exports:{}};new Function('module','exports',code)(mod,mod.exports);const {createAuthSession}=mod.exports;
const url='https://accounts.google.com/o/oauth2/v2/auth?scope=openid+email+profile&code_challenge_method=S256';
const data=new Map(),calls=[];let writeHook=null,pollHook=null,openHook=null;
const store={getItemAsync:async k=>data.get(k),setItemAsync:async(k,v)=>{data.set(k,v);if(writeHook)await writeHook(k,v);},deleteItemAsync:async k=>{data.delete(k);}};
const deferred=()=>{let resolve;const promise=new Promise(r=>resolve=r);return {promise,resolve};};
const fetcher=async(url,options)=>{const p=new URL(url).pathname;calls.push({url,options});let value;
 if(p==='/sso/google/begin')value={ok:true,url:globalGoogleURL,poll:'fixture-poll'};
 else if(p==='/sso/google/poll')value=pollHook?await pollHook():{ok:true,token:'fixture-google'};
 else if(p==='/user/login'||p==='/user/register')value={token:'fixture-password'};
 else value={result:p.endsWith('status')?{username:'existing',google:true}:p.endsWith('admission')?{admitted:true}:p.endsWith('recover')?{token:'fixture-recovered'}:{}};
 return {ok:true,status:200,json:async()=>({data:value})};};
let globalGoogleURL=url;
const client=origin=>createAuthSession({origin,store,fetcher,openURL:async()=>{if(openHook)await openHook();},delay:async()=>{}});
(async()=>{
 const a=client('https://example.test:8001'),b=client('https://example.test:8443');
 assert.equal(await a.restoreSession(),false);await a.authenticateProvider('google');assert.equal(await b.restoreSession(),false);assert.equal(await a.rpc('auth_google_status').then(r=>r.username),'existing');
 assert.equal(calls.at(-1).options.headers.Authorization,'Bearer fixture-google');assert.ok(calls.filter(c=>c.url.includes('/sso/')).every(c=>!c.options.headers.Authorization));
 assert.ok(calls.every(c=>c.options.redirect==='error'));assert.ok([...data.keys()].every(k=>k.startsWith('stack.ui-auth.v1.')));assert.ok(!data.has('stack.session.v1'));
 const before=calls.length;await assert.rejects(()=>a.rpc('bootstrap'),/only connects/);await assert.rejects(()=>a.authenticateProvider('apple'),/not connected/);assert.equal(calls.length,before);
 await a.authenticate('existing','fixture-password',false);await a.authenticateProvider('google',true);const begin=calls.filter(c=>c.url.endsWith('/begin')).at(-1);assert.equal(begin.options.headers.Authorization,'Bearer fixture-password');
 // Cancel while SecureStore is adopting a returned session: prior linked session survives.
 const persisted=deferred(),release=deferred();writeHook=async(k,v)=>{if(k.endsWith('.session')&&v==='fixture-google'){persisted.resolve();await release.promise;}};
 await a.authenticate('existing','fixture-password',false);const adopting=a.authenticateProvider('google',true);const rejected=assert.rejects(adopting,/cancelled|changed/);await persisted.promise;const cancelling=a.cancel();release.resolve();await cancelling;await rejected;writeHook=null;await a.rpc('auth_google_status');assert.equal(calls.at(-1).options.headers.Authorization,'Bearer fixture-password');
 // Cancellation after Safari opens must not adopt or poll a late result.
 const opened=deferred(),returnSafari=deferred();openHook=async()=>{opened.resolve();await returnSafari.promise;};const opening=a.authenticateProvider('google');const rejectOpen=assert.rejects(opening,/cancelled/);await opened.promise;await a.cancel();returnSafari.resolve();await rejectOpen;openHook=null;
 // A persisted handoff resumes after relaunch in the same origin only.
 const failed=client('https://resume.test');pollHook=async()=>{throw Error('offline');};await assert.rejects(()=>failed.authenticateProvider('google'),/offline/);pollHook=null;const restored=client('https://resume.test');assert.equal(await restored.restoreSession(),true);await restored.signOut();assert.equal(await client('https://resume.test').restoreSession(),false);
 globalGoogleURL=url+'&scope=https://www.googleapis.com/auth/gmail.readonly';await assert.rejects(()=>a.authenticateProvider('google'),/permissions/);globalGoogleURL=url;
 await a.recover('existing','fixture-password');await a.rpc('auth_google_status');assert.equal(calls.at(-1).options.headers.Authorization,'Bearer fixture-recovered');await a.signOut();assert.equal(await a.restoreSession(),false);
 // Older production gateways omit optional Google metadata; admission failures must still propagate.
 let missingStatus=404;
 const production=createAuthSession({origin:'https://production.test',store,openURL:async()=>{},fetcher:async()=>({ok:false,status:missingStatus,json:async()=>{throw new SyntaxError('HTML response');}})});
 assert.deepEqual(await production.rpc('auth_google_status'),{});
 await assert.rejects(()=>production.rpc('agent_admission'),e=>e.status===404);
 missingStatus=401;await assert.rejects(()=>production.rpc('auth_google_status'),e=>e.status===401);
 const {settings}=require('../scripts/auth-build-config.cjs');assert.equal(settings({}).mode,'mock');assert.throws(()=>settings({STACK_AUTH_MODE:'typo'}));assert.throws(()=>settings({STACK_AUTH_MODE:'google-test',STACK_AUTH_API_URL:'http://example.test'}));assert.equal(settings({STACK_AUTH_MODE:'google-test',STACK_AUTH_API_URL:'https://example.test/'}).origin,'https://example.test');
 console.log('PASS real-auth protocol, origin isolation, scoped credentials, link/recovery, relaunch, cancellation races, RPC boundary and fail-closed build configuration.');
})().catch(e=>{console.error(e);process.exit(1);});
