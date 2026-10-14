// Exercise the actual handoff helpers with fake browser/OS boundaries.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {webcrypto}=require('node:crypto');
async function load(file){return import('data:text/javascript;base64,'+fs.readFileSync(path.join(__dirname,'..',file)).toString('base64'));}
async function main(){
 const web=await load('web/google-auth.js'),native=await load('native/google-auth.js');
 global.crypto=webcrypto;
 const saved=new Map(),store={getItemAsync:async k=>saved.get(k),setItemAsync:async(k,v)=>saved.set(k,v),deleteItemAsync:async k=>saved.delete(k)};
 global.sessionStorage={getItem:k=>saved.get(k),setItem:(k,v)=>saved.set(k,v),removeItem:k=>saved.delete(k)};
 let navigation='',replaced='';global.location={pathname:'/',search:'',assign:url=>{navigation=url;}};global.history={replaceState:(_,__,url)=>{replaced=url;}};
 const state='s'.repeat(43),url='https://accounts.google.com/o/oauth2/v2/auth?scope=openid+email+profile&code_challenge_method=S256';
 let calls=[];
 const begin=async(...args)=>{calls.push(args);return {ok:true,state,url,poll:'p'.repeat(43)};};
 await web.beginGoogle(begin,'invite-fixture',false);
 assert.equal(navigation,url);assert.equal(calls[0][2],false);assert.equal(calls[0][1].challenge.length,43);
 let pending=JSON.parse(saved.get('stack.google.signin.v1'));
 const expected=Buffer.from(await webcrypto.subtle.digest('SHA-256',new TextEncoder().encode(pending.verifier))).toString('base64url');assert.equal(expected,calls[0][1].challenge);
 global.location={pathname:'/auth/google',search:'?code=fixture&state='+state};
 // Exercise the actual legacy parser before the SSO helper, as the web entry does.
 const transport=fs.readFileSync(path.join(__dirname,'..','web/transport.js'),'utf8');
 const parser=transport.match(/export function oauthResult\(\)\{[^\n]+/)[0].replace('export ','');
 const oauthResult=Function(parser+';return oauthResult;')();
 assert.deepEqual(oauthResult(),{});assert.equal(global.location.search,'?code=fixture&state='+state);
 const signed=await web.finishGoogle(async(route,body,authenticated)=>{assert.equal(route,'/sso/google/finish');assert.equal(body.verifier,pending.verifier);assert.equal(authenticated,false);return {ok:true,token:'fixture-jwt'};});
 assert.equal(signed.token,'fixture-jwt');assert.equal(signed.invite,'invite-fixture');assert.equal(replaced,'/');assert.equal(saved.size,0);
 await assert.rejects(()=>web.finishGoogle(begin),/expired/);
 global.location={pathname:'/',assign:url=>{navigation=url;}};await web.beginGoogle(begin,'',true);assert.equal(calls.at(-1)[2],true);
 global.location={pathname:'/auth/google',search:'?error=access_denied&state='+state};
 await assert.rejects(()=>web.finishGoogle(async(route,body)=>{assert.equal(body.code,'');return {ok:false,error:'denied'};}),/cancelled/);assert.equal(saved.size,0);
 global.location={pathname:'/',assign(){}};await web.beginGoogle(begin);
 global.location={pathname:'/auth/google',search:'?code=fixture&state=wrong'};let exchanged=false;
 await assert.rejects(()=>web.finishGoogle(async()=>{exchanged=true;}),/another tab/);assert.equal(exchanged,false);
 assert.throws(()=>web.googleURL(url+'&scope=https://www.googleapis.com/auth/gmail.readonly'),/permissions/); // duplicate also must not expand identity scopes
 assert.throws(()=>web.googleURL('https://attacker.example/'),/invalid/);
 calls=[];let opened='';pending=await native.beginGoogle(begin,store,async url=>{opened=url;},'',true);
 assert.equal(calls[0][1].mode,'native');assert.equal(calls[0][2],true);assert.equal(opened,url);assert.equal((await native.pendingGoogle(store)).poll,pending.poll);
 let polls=0;const result=await native.waitGoogle(async(route,body,auth)=>{assert.equal(route,'/sso/google/poll');assert.equal(body.poll,pending.poll);assert.equal(auth,false);return ++polls===1?{ok:false,token:'',error:''}:{ok:true,token:'fixture-native-jwt'};},store,pending,()=>true,async()=>{});
 assert.equal(result.token,'fixture-native-jwt');assert.equal(result.linked,true);assert.equal(saved.size,0);
 pending=await native.beginGoogle(begin,store,async()=>{});
 await assert.rejects(()=>native.waitGoogle(async()=>{await native.cancelGoogle(store);return {ok:true,token:'late-jwt'};},store,pending),/cancelled/);assert.equal(saved.size,0);
 pending=await native.beginGoogle(begin,store,async()=>{});
 await assert.rejects(()=>native.waitGoogle(async()=>({ok:false,error:'provider denied'}),store,pending),/cancelled/);
 assert.equal(saved.size,0);
 // Cancelling while the OS is deleting the completed pending handoff must win.
 pending=await native.beginGoogle(begin,store,async()=>{});
 let releaseDelete,enteredDelete;
 const deletionEntered=new Promise(resolve=>{enteredDelete=resolve;});
 let defer=true;
 const delayedStore={...store,deleteItemAsync:async key=>{if(defer){defer=false;enteredDelete();await new Promise(resolve=>{releaseDelete=resolve;});}await store.deleteItemAsync(key);}};
 const delayedResult=native.waitGoogle(async()=>({ok:true,token:'cancelled-jwt'}),delayedStore,pending);
 await deletionEntered;await native.cancelGoogle(store);releaseDelete();
 await assert.rejects(()=>delayedResult,/cancelled/);assert.equal(saved.size,0);
 // Cancellation during opening Safari cannot start polling under a newer attempt.
 await assert.rejects(()=>native.beginGoogle(begin,store,async()=>{await native.cancelGoogle(store);}),/cancelled/);
 // Exercise the device's actual adoption function when cancellation occurs during SecureStore persistence.
 const device=fs.readFileSync(path.join(__dirname,'..','native/device.js'),'utf8');
 const adoptSource=device.slice(device.indexOf('async function adoptGoogle('),device.indexOf('export async function restoreSession'));
 let releaseWrite,enteredWrite,storedSession='existing-jwt',firstWrite=true;
 const writeEntered=new Promise(resolve=>{enteredWrite=resolve;});
 const deviceStore={setItemAsync:async(key,value)=>{if(firstWrite){firstWrite=false;enteredWrite();await new Promise(resolve=>{releaseWrite=resolve;});}storedSession=value;},deleteItemAsync:async()=>{storedSession='';}};
 const harness=Function('SecureStore','waitGoogle','AppState','rpc',"let token='existing-jwt',generation=0;const sessionKey='fixture-session';const request=()=>{};"+adoptSource+';return {adoptGoogle,cancel:()=>{generation++;},current:()=>token};')(deviceStore,async()=>({token:'cancelled-jwt'}),{currentState:'active'},async()=>{});
 const adoption=harness.adoptGoogle({});await writeEntered;harness.cancel();releaseWrite();
 await assert.rejects(()=>adoption,/session changed/);assert.equal(harness.current(),'existing-jwt');assert.equal(storedSession,'existing-jwt');
 console.log('Web and native handoff: PKCE, linking, cancellation, replay, tab binding and late-result rejection passed.');
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
