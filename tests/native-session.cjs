const assert = require('node:assert/strict'), fs = require('node:fs');
const source = fs.readFileSync(require.resolve('../native/device.js'),'utf8');
const part = source.slice(source.indexOf('export const apiBase'),source.indexOf('async function adoptGoogle')).replace(/export /g,'');
const calls=[]; let reply;
const device = Function('Constants','Files','fetch',part+';return {borrowSession,request};')({expoConfig:{extra:{apiBaseUrl:'https://legacy.example'}}},{cacheDirectory:'file://cache/'},async(url,options)=>{calls.push({url,options});if(reply)await reply;return {ok:true,json:async()=>({data:{result:{ok:true}}})};});
(async()=>{
 let token='first-session';device.borrowSession({origin:'https://stack.example.com',token:()=>token});
 await device.request('/function/bootstrap',{});
 assert.equal(calls[0].url,'https://stack.example.com/function/bootstrap');
 assert.equal(calls[0].options.headers.Authorization,'Bearer first-session');
 let resolve;reply=new Promise(r=>{resolve=r;});const pending=device.request('/function/bootstrap',{});token='second-session';resolve();
 await assert.rejects(()=>pending,/Session changed/);reply=null;
 await device.request('/function/bootstrap',{});assert.equal(calls.at(-1).options.headers.Authorization,'Bearer second-session');
 token='';await device.request('/user/login',{},false);assert.equal(calls.at(-1).options.headers.Authorization,undefined);
 console.log('PASS native shared session: configured origin, current account credentials and stale-account response rejection.');
})().catch(e=>{console.error(e);process.exitCode=1;});
