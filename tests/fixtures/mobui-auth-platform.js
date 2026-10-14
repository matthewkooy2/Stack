// Browser test fixture only. Never staged into the native build.
import {createAuthSession} from '../../mobile/auth-session.js';
export const realAuthEnabled=true;
export const liveData=false;
const saved=new Map();
const fixture=globalThis.__authFixture={calls:[],admitted:true,linked:true,recoverable:false,hold:false,username:'existing-account'};
export const authSession=createAuthSession({origin:'https://auth-fixture.invalid',store:{getItemAsync:async k=>saved.get(k),setItemAsync:async(k,v)=>saved.set(k,v),deleteItemAsync:async k=>saved.delete(k)},openURL:async()=>{fixture.opened=true;},delay:()=>new Promise(r=>setTimeout(r,40)),fetcher:async(url,options)=>{
 const route=new URL(url).pathname,body=JSON.parse(options.body);fixture.calls.push(route);let value;
 if(route==='/sso/google/begin'){fixture.linking=!!options.headers.Authorization;value={ok:true,poll:'fixture-capability',url:'https://accounts.google.com/o/oauth2/v2/auth?scope=openid+email+profile&code_challenge_method=S256'};}
 else if(route==='/sso/google/poll'){if(fixture.hold)value={ok:false,error:''};else{fixture.linked=true;value={ok:true,token:'fixture-session'};}}
 else if(route.startsWith('/user/'))value={token:'fixture-session'};
 else if(route.endsWith('/auth_google_status'))value={result:{username:fixture.username,google:fixture.linked,can_recover:fixture.recoverable}};
 else if(route.endsWith('/agent_admission'))value={result:{admitted:fixture.admitted}};
 else if(route.endsWith('/agent_accept_invite')){if(body.invite==='valid-fixture'){fixture.admitted=true;value={result:{ok:true}};}else value={result:{error:'Invitation is invalid.'}};}
 else if(route.endsWith('/auth_google_recover')){fixture.username=body.username;fixture.recoverable=false;fixture.admitted=true;value={result:{token:'fixture-recovered'}};}
 else throw Error('Unexpected real endpoint: '+route);
 return {ok:true,status:200,json:async()=>({data:value})};
}});
